use serde_json::{Value, json};
use std::{
    io::Write,
    process::{Command, Stdio},
};
use tempfile::tempdir;

fn run_daemon_with_input(input: &str) -> Vec<Value> {
    let mut child = Command::new(env!("CARGO_BIN_EXE_simpletree-daemon"))
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn simpletree-daemon");

    child
        .stdin
        .take()
        .expect("daemon stdin")
        .write_all(input.as_bytes())
        .expect("write daemon input");

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

#[test]
fn version_flag_reports_the_cargo_package_version() {
    let output = Command::new(env!("CARGO_BIN_EXE_simpletree-daemon"))
        .arg("--version")
        .output()
        .expect("run --version");

    assert!(output.status.success());
    assert_eq!(
        String::from_utf8(output.stdout).expect("UTF-8 version output"),
        format!("simpletree-daemon {}\n", env!("CARGO_PKG_VERSION"))
    );
}

#[test]
fn ping_reports_protocol_version_and_capabilities() {
    let events = run_daemon_with_input(&format!("{}\n", json!({"type": "ping", "id": 91})));
    assert_eq!(events.len(), 1);

    let pong = &events[0];
    assert_eq!(pong["type"], "pong");
    assert_eq!(pong["id"], 91);
    assert!(pong["protocol_version"].as_u64().is_some_and(|v| v > 0));
    assert_eq!(pong["daemon_version"], env!("CARGO_PKG_VERSION"));

    let capabilities = pong["capabilities"].as_array().expect("capability array");
    for capability in ["list", "cancel", "ping"] {
        assert!(
            capabilities.iter().any(|value| value == capability),
            "missing capability: {capability}"
        );
    }
}

#[test]
fn unknown_cli_argument_fails_without_starting_protocol_mode() {
    let output = Command::new(env!("CARGO_BIN_EXE_simpletree-daemon"))
        .arg("--unknown")
        .output()
        .expect("run unknown argument");

    assert!(!output.status.success());
    assert!(String::from_utf8_lossy(&output.stderr).contains("unknown command-line argument"));
}

/// The handshake is what the Vim side gates every optional feature on, so an
/// announcement that drifts from what the daemon will actually do is invisible
/// until a user hits it.  `--self-test` used to "check" this by calling
/// `runtime_capabilities(true, true)` itself and asserting a capability that
/// function pushes unconditionally, so changing the real handshake to
/// `runtime_capabilities(false, git_available)` left every check green.  This
/// asks the daemon to do the thing, and then requires it to have said so.
#[test]
fn the_handshake_announces_exactly_what_the_daemon_will_do() {
    let directory = tempdir().expect("temporary directory");
    let events = run_daemon_with_input(&format!(
        "{}\n{}\n",
        json!({"type": "ping", "id": 91}),
        json!({"type": "watch", "id": 92, "path": directory.path()}),
    ));

    let pong = events
        .iter()
        .find(|event| event["type"] == "pong")
        .unwrap_or_else(|| panic!("no pong: {events:?}"));
    let announced: Vec<&str> = pong["capabilities"]
        .as_array()
        .expect("capability array")
        .iter()
        .filter_map(|value| value.as_str())
        .collect();

    let watch_reply = events
        .iter()
        .find(|event| event["id"] == 92)
        .unwrap_or_else(|| panic!("no reply to the watch request: {events:?}"));
    let watching = watch_reply["type"] == "ok";
    assert_eq!(
        watching,
        announced.contains(&"watch"),
        "the handshake and the watch request disagree: {pong:?} vs {watch_reply:?}"
    );

    let git_works = Command::new("git")
        .arg("--version")
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .is_ok_and(|status| status.success());
    assert_eq!(
        git_works,
        announced.contains(&"git-status"),
        "git is {}available but the handshake says otherwise: {pong:?}",
        if git_works { "" } else { "un" }
    );

    // These two are unconditional; if one ever stops being served, it must stop
    // being announced in the same commit.
    for capability in [
        "search",
        "fs-ops",
        "chunked-results",
        "metadata",
        "warnings",
    ] {
        assert!(
            announced.contains(&capability),
            "missing capability {capability}: {pong:?}"
        );
    }
}
