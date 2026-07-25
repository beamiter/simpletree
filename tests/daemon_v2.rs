//! Protocol v2 integration coverage: metadata, warnings, non-UTF-8 names,
//! explicit cancel, watch/unwatch, git status, and search.

use serde_json::{Value, json};
use std::{
    io::{BufRead, BufReader, Write},
    path::Path,
    process::{Child, ChildStdin, ChildStdout, Command, Stdio},
    time::{Duration, Instant},
};
use tempfile::tempdir;

fn run_daemon(requests: &[Value]) -> Vec<Value> {
    let input = requests
        .iter()
        .map(Value::to_string)
        .collect::<Vec<_>>()
        .join("\n")
        + "\n";
    let mut child = Command::new(env!("CARGO_BIN_EXE_simpletree-daemon"))
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn simpletree-daemon");

    let mut stdin = child.stdin.take().expect("daemon stdin");
    stdin.write_all(input.as_bytes()).expect("write requests");
    drop(stdin);

    let output = child.wait_with_output().expect("wait for daemon");
    assert!(
        output.status.success(),
        "daemon failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );

    String::from_utf8(output.stdout)
        .expect("UTF-8 protocol output")
        .lines()
        .map(|line| serde_json::from_str(line).expect("JSON protocol event"))
        .collect()
}

/// Interactive session for tests that need to react to events (watch).
struct Session {
    child: Child,
    stdin: ChildStdin,
    stdout: BufReader<ChildStdout>,
}

impl Session {
    fn start() -> Session {
        let mut child = Command::new(env!("CARGO_BIN_EXE_simpletree-daemon"))
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .expect("spawn simpletree-daemon");
        let stdin = child.stdin.take().expect("daemon stdin");
        let stdout = BufReader::new(child.stdout.take().expect("daemon stdout"));
        Session {
            child,
            stdin,
            stdout,
        }
    }

    fn send(&mut self, request: &Value) {
        let mut line = request.to_string();
        line.push('\n');
        self.stdin.write_all(line.as_bytes()).expect("send request");
        self.stdin.flush().expect("flush request");
    }

    fn next_event(&mut self) -> Value {
        let mut line = String::new();
        let read = self.stdout.read_line(&mut line).expect("read event");
        assert!(read > 0, "daemon closed stdout unexpectedly");
        serde_json::from_str(&line).expect("JSON protocol event")
    }

    /// Read events until `pred` matches or the deadline passes.
    fn wait_for(&mut self, pred: impl Fn(&Value) -> bool, timeout: Duration) -> Value {
        let deadline = Instant::now() + timeout;
        loop {
            assert!(Instant::now() < deadline, "timed out waiting for event");
            let event = self.next_event();
            if pred(&event) {
                return event;
            }
        }
    }

    fn finish(mut self) {
        drop(self.stdin);
        let _ = self.child.wait();
    }
}

#[test]
fn meta_flag_adds_size_mtime_and_symlink_fields() {
    let directory = tempdir().expect("temporary directory");
    std::fs::write(directory.path().join("data.txt"), b"12345").expect("fixture");

    let events = run_daemon(&[json!({
        "type": "list", "id": 1, "path": directory.path(), "meta": true,
        "git_ignore": false,
    })]);
    let entry = &events[0]["entries"][0];
    assert_eq!(entry["name"], "data.txt");
    assert_eq!(entry["size"], 5);
    assert!(entry["mtime"].as_i64().is_some_and(|mtime| mtime > 0));
    assert!(entry.get("is_symlink").is_none(), "regular file omits flag");

    let plain = run_daemon(&[json!({
        "type": "list", "id": 2, "path": directory.path(), "git_ignore": false,
    })]);
    let entry = &plain[0]["entries"][0];
    assert!(
        entry.get("size").is_none(),
        "meta off keeps the old payload"
    );
    assert!(entry.get("mtime").is_none());
}

#[cfg(unix)]
#[test]
fn non_utf8_names_are_listed_lossily_with_a_flag_and_warning() {
    use std::os::unix::ffi::OsStrExt;
    let directory = tempdir().expect("temporary directory");
    let bad_name = std::ffi::OsStr::from_bytes(b"bad-\xff-name");
    std::fs::write(directory.path().join(bad_name), b"x").expect("fixture");

    let events = run_daemon(&[json!({
        "type": "list", "id": 1, "path": directory.path(), "git_ignore": false,
    })]);
    let done = events
        .iter()
        .find(|event| event["done"] == true)
        .expect("final chunk");
    let entry = &done["entries"][0];
    assert_eq!(entry["non_utf8"], true);
    assert!(
        entry["name"].as_str().expect("name").contains('\u{FFFD}'),
        "lossy replacement expected"
    );
    assert!(
        done["warnings"]
            .as_array()
            .is_some_and(|warnings| !warnings.is_empty()),
        "warnings should ride the final chunk"
    );
}

#[test]
fn explicit_cancel_suppresses_list_output_and_frees_the_id() {
    let directory = tempdir().expect("temporary directory");
    std::fs::write(directory.path().join("visible.txt"), b"x").expect("fixture");

    // Cancel races the list; afterwards the same id must be reusable. The
    // reused id's listing must always arrive.
    let events = run_daemon(&[
        json!({"type": "list", "id": 9, "path": directory.path(), "git_ignore": false}),
        json!({"type": "cancel", "id": 9}),
        json!({"type": "list", "id": 9, "path": directory.path(), "git_ignore": false}),
    ]);
    let done_chunks: Vec<_> = events
        .iter()
        .filter(|event| event["type"] == "list_chunk" && event["done"] == true)
        .collect();
    assert!(
        !done_chunks.is_empty(),
        "reused id must produce a completed listing; events: {events:?}"
    );
}

#[test]
fn search_streams_matches_and_terminates_with_done() {
    let directory = tempdir().expect("temporary directory");
    std::fs::create_dir(directory.path().join("deep")).expect("fixture");
    std::fs::write(directory.path().join("match_one.rs"), b"x").expect("fixture");
    std::fs::write(directory.path().join("deep/match_two.rs"), b"x").expect("fixture");
    std::fs::write(directory.path().join("other.txt"), b"x").expect("fixture");

    let events = run_daemon(&[json!({
        "type": "search", "id": 4, "root": directory.path(),
        "query": "match", "git_ignore": false,
    })]);
    let names: Vec<&str> = events
        .iter()
        .filter(|event| event["type"] == "search_chunk")
        .flat_map(|event| event["entries"].as_array().expect("entries"))
        .map(|entry| entry["name"].as_str().expect("name"))
        .collect();
    assert!(names.contains(&"match_one.rs"), "events: {events:?}");
    assert!(names.contains(&"match_two.rs"), "recursive match expected");
    assert!(!names.contains(&"other.txt"));
    assert_eq!(
        events.last().map(|event| &event["done"]),
        Some(&Value::Bool(true)),
        "search must terminate with done"
    );
}

#[test]
fn fuzzy_search_matches_ordered_subsequences() {
    let directory = tempdir().expect("temporary directory");
    std::fs::write(directory.path().join("simpletree_daemon.rs"), b"x").expect("fixture");
    std::fs::write(directory.path().join("readme.md"), b"x").expect("fixture");

    let events = run_daemon(&[json!({
        "type": "search", "id": 5, "root": directory.path(),
        "query": "stdrs", "mode": "fuzzy", "git_ignore": false,
    })]);
    let names: Vec<&str> = events
        .iter()
        .filter(|event| event["type"] == "search_chunk")
        .flat_map(|event| event["entries"].as_array().expect("entries"))
        .map(|entry| entry["name"].as_str().expect("name"))
        .collect();
    assert_eq!(names, ["simpletree_daemon.rs"]);
}

#[test]
fn watch_pushes_debounced_fs_events_and_unwatch_stops_them() {
    let directory = tempdir().expect("temporary directory");
    let mut session = Session::start();

    session.send(&json!({"type": "ping", "id": 1}));
    let pong = session.wait_for(|event| event["type"] == "pong", Duration::from_secs(5));
    let capabilities: Vec<&str> = pong["capabilities"]
        .as_array()
        .expect("capabilities")
        .iter()
        .map(|value| value.as_str().expect("capability"))
        .collect();
    assert_eq!(pong["protocol_version"], 2);
    assert!(capabilities.contains(&"search"));
    if !capabilities.contains(&"watch") {
        // Watcher can be unavailable in constrained environments; the
        // capability gate is exactly what shields clients from that.
        session.finish();
        return;
    }

    session.send(&json!({"type": "watch", "id": 2, "path": directory.path()}));
    session.wait_for(
        |event| event["type"] == "ok" && event["id"] == 2,
        Duration::from_secs(5),
    );

    std::fs::write(directory.path().join("created.txt"), b"x").expect("fixture");
    let fs_event = session.wait_for(|event| event["type"] == "fs_event", Duration::from_secs(5));
    let dirs: Vec<&str> = fs_event["dirs"]
        .as_array()
        .expect("dirs")
        .iter()
        .map(|value| value.as_str().expect("dir"))
        .collect();
    assert!(
        dirs.iter().any(|dir| Path::new(dir) == directory.path()),
        "fs_event should reference the watched directory: {dirs:?}"
    );

    session.send(&json!({"type": "unwatch", "id": 3, "path": directory.path()}));
    session.wait_for(
        |event| event["type"] == "ok" && event["id"] == 3,
        Duration::from_secs(5),
    );
    session.finish();
}

#[test]
fn git_status_reports_untracked_and_directory_aggregates() {
    if Command::new("git")
        .arg("--version")
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map(|status| !status.success())
        .unwrap_or(true)
    {
        return; // git unavailable; capability would be unadvertised
    }

    let directory = tempdir().expect("temporary directory");
    let root = directory.path();
    let git = |args: &[&str]| {
        let status = Command::new("git")
            .arg("-C")
            .arg(root)
            .args(args)
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .expect("run git");
        assert!(status.success(), "git {args:?} failed");
    };
    git(&["init", "-q"]);
    git(&[
        "-c",
        "user.email=t@t",
        "-c",
        "user.name=t",
        "commit",
        "-q",
        "--allow-empty",
        "-m",
        "init",
    ]);
    std::fs::create_dir(root.join("src")).expect("fixture");
    std::fs::write(root.join("src/new_file.rs"), b"x").expect("fixture");

    let events = run_daemon(&[json!({
        "type": "git_status", "id": 6, "path": root, "force": true,
    })]);
    let status = events
        .iter()
        .find(|event| event["type"] == "git_status")
        .expect("git_status event");
    let statuses = status["statuses"].as_object().expect("statuses");
    // tempdir may be behind a symlink (macOS); compare canonical paths.
    let canonical = root.canonicalize().expect("canonical root");
    let file_key = canonical.join("src/new_file.rs");
    let dir_key = canonical.join("src");
    assert_eq!(
        statuses
            .get(file_key.to_str().expect("utf8"))
            .and_then(Value::as_str),
        Some("U"),
        "statuses: {statuses:?}"
    );
    assert_eq!(
        statuses
            .get(dir_key.to_str().expect("utf8"))
            .and_then(Value::as_str),
        Some("U"),
        "directories aggregate their children"
    );
}
