//! A cancelled `git status` must not outlive its request.
//!
//! Tree navigation cancels and reissues status on every cursor move, so the
//! dropped future is the normal path, not the edge case.  `git.rs` awaited
//! `command.output()` with neither `kill_on_drop(true)` nor any timeout:
//! dropping a tokio `Child` without `kill_on_drop` *detaches* it, so every
//! cancelled `git status --untracked-files=all` kept walking the whole
//! worktree into a pipe with no reader, none of them could be stopped, and
//! none would ever be timed out.  Ten cursor moves in a second left ten full
//! status walks running.
//!
//! The test puts a `git` on the daemon's PATH that hangs, cancels the request
//! once that process exists, and requires it to be gone afterwards.

use serde_json::{Value, json};
use std::{
    io::{BufRead, BufReader, Write},
    path::Path,
    process::{Command, Stdio},
    time::{Duration, Instant},
};
use tempfile::tempdir;

/// A `git` that answers `--version` (the daemon probes it at startup) and
/// hangs on anything else, recording its own pid first.  `exec` keeps the pid
/// in the marker file the one that has to die.
fn fake_git(bin_dir: &Path, marker: &Path) {
    std::fs::create_dir_all(bin_dir).expect("fixture");
    let script = format!(
        "#!/bin/sh\n\
         case \" $* \" in\n\
         *\" --version \"*) echo 'git version 2.45.0'; exit 0 ;;\n\
         esac\n\
         echo $$ > '{}'\n\
         exec sleep 300\n",
        marker.display()
    );
    let path = bin_dir.join("git");
    std::fs::write(&path, script).expect("fixture");
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).expect("fixture");
    }
}

fn fake_repo(root: &Path) {
    std::fs::create_dir_all(root.join(".git")).expect("fixture");
    std::fs::write(root.join(".git/HEAD"), b"ref: refs/heads/main\n").expect("fixture");
}

fn still_running(pid: &str) -> bool {
    Command::new("kill")
        .args(["-0", pid])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .is_ok_and(|status| status.success())
}

#[test]
#[cfg(unix)]
fn cancelling_a_status_request_kills_the_git_it_started() {
    let directory = tempdir().expect("temporary directory");
    let repo = directory.path().join("repo");
    let marker = directory.path().join("git.pid");
    fake_repo(&repo);
    fake_git(&directory.path().join("bin"), &marker);

    let path = format!(
        "{}:{}",
        directory.path().join("bin").display(),
        std::env::var("PATH").unwrap_or_default()
    );
    let mut child = Command::new(env!("CARGO_BIN_EXE_simpletree-daemon"))
        .env("PATH", path)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn simpletree-daemon");
    let mut stdin = child.stdin.take().expect("daemon stdin");

    writeln!(
        stdin,
        "{}",
        json!({"type": "git_status", "id": 1, "path": repo})
    )
    .expect("write git_status");
    stdin.flush().expect("flush");

    // Wait until git has actually been spawned; cancelling before that would
    // prove nothing, because there would be no child to leak.
    let deadline = Instant::now() + Duration::from_secs(10);
    let pid = loop {
        if let Ok(contents) = std::fs::read_to_string(&marker) {
            let pid = contents.trim().to_owned();
            if !pid.is_empty() {
                break pid;
            }
        }
        assert!(Instant::now() < deadline, "the daemon never ran git");
        std::thread::sleep(Duration::from_millis(20));
    };
    assert!(still_running(&pid), "the fixture exited on its own");

    writeln!(stdin, "{}", json!({"type": "cancel", "id": 1})).expect("write cancel");
    writeln!(stdin, "{}", json!({"type": "ping", "id": 2})).expect("write ping");
    stdin.flush().expect("flush");

    // The loop must still answer while a status walk is in flight.
    let stdout = BufReader::new(child.stdout.take().expect("daemon stdout"));
    let mut answered = false;
    for line in stdout.lines() {
        let event: Value = serde_json::from_str(&line.expect("read event")).expect("JSON event");
        if event["type"] == "pong" && event["id"] == 2 {
            answered = true;
            break;
        }
    }
    assert!(answered, "the daemon never answered the ping");

    drop(stdin);
    let status = child.wait().expect("wait for daemon");
    assert!(status.success(), "daemon exited with {status}");

    // Killing is asynchronous only in that the reaper runs later; the signal
    // itself goes out in the future's destructor.
    let deadline = Instant::now() + Duration::from_secs(5);
    while still_running(&pid) {
        assert!(
            Instant::now() < deadline,
            "the cancelled git status is still walking the worktree (pid {pid})"
        );
        std::thread::sleep(Duration::from_millis(20));
    }
}
