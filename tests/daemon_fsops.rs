//! End-to-end coverage for the `fs_op` request: the protocol shape the Vim
//! frontend depends on, and the guarantee that motivates the whole feature —
//! a copy that fails or is cancelled must leave the destination exactly as it
//! was, because the frontend has already told the user the old file is safe.

use serde_json::{Value, json};
use std::{
    io::{BufRead, BufReader, Write},
    process::{Child, ChildStdin, ChildStdout, Command, Stdio},
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

    fn finish(mut self) {
        drop(self.stdin);
        let _ = self.child.wait();
    }
}

#[test]
fn the_handshake_advertises_fs_ops() {
    let events = run_daemon(&[json!({"type": "ping", "id": 1})]);
    let capabilities = events[0]["capabilities"]
        .as_array()
        .expect("capability array");
    assert!(
        capabilities.iter().any(|value| value == "fs-ops"),
        "handshake omitted fs-ops: {capabilities:?}"
    );
}

#[test]
fn copy_installs_the_source_and_reports_the_outcome_fields() {
    let directory = tempdir().expect("temporary directory");
    let src = directory.path().join("src.txt");
    let dst = directory.path().join("dst.txt");
    std::fs::write(&src, b"payload").expect("fixture");

    let events = run_daemon(&[json!({
        "type": "fs_op", "id": 3, "op": "copy", "src": src, "dst": dst,
    })]);
    let done = &events[0];
    assert_eq!(done["type"], "fs_op_done");
    assert_eq!(done["id"], 3);
    assert_eq!(done["installed"], true);
    assert_eq!(done["source_removed"], false);
    assert_eq!(done["message"], "");
    assert_eq!(std::fs::read(&dst).unwrap(), b"payload");
    assert!(src.exists(), "copy must keep its source");
}

#[test]
fn move_reports_the_source_gone_and_remove_reports_the_path_gone() {
    let directory = tempdir().expect("temporary directory");
    let src = directory.path().join("a.txt");
    let moved = directory.path().join("b.txt");
    std::fs::write(&src, b"x").expect("fixture");

    // fs_ops run concurrently like every other request, so a test that depends
    // on one finishing before the next begins has to wait rather than pipeline —
    // exactly what the frontend does by chaining its jobs through callbacks.
    let mut session = Session::start();
    session.send(&json!({"type": "fs_op", "id": 1, "op": "move", "src": src, "dst": moved}));
    let done = session.next_event();
    assert_eq!(done["id"], 1);
    assert_eq!(done["installed"], true);
    assert_eq!(done["source_removed"], true);
    assert!(!src.exists());

    session.send(&json!({"type": "fs_op", "id": 2, "op": "remove", "src": moved}));
    let done = session.next_event();
    assert_eq!(done["id"], 2);
    assert_eq!(done["installed"], true);
    assert!(!moved.exists());
    session.finish();
}

/// The reason the whole operation is staged: the frontend has already promised
/// the user that a failed paste changes nothing.
#[test]
fn a_refused_copy_leaves_the_existing_destination_intact() {
    let directory = tempdir().expect("temporary directory");
    let dst = directory.path().join("keep.txt");
    std::fs::write(&dst, b"original").expect("fixture");
    let missing = directory.path().join("does-not-exist");

    let events = run_daemon(&[json!({
        "type": "fs_op", "id": 9, "op": "copy", "src": missing, "dst": dst,
    })]);
    assert_eq!(events[0]["installed"], false);
    assert!(
        events[0]["message"]
            .as_str()
            .expect("message")
            .contains("source does not exist")
    );
    assert_eq!(std::fs::read(&dst).unwrap(), b"original");
    let leftovers: Vec<String> = std::fs::read_dir(directory.path())
        .unwrap()
        .map(|entry| entry.unwrap().file_name().to_string_lossy().into_owned())
        .filter(|name| name.starts_with(".simpletree-"))
        .collect();
    assert!(leftovers.is_empty(), "staging leftovers: {leftovers:?}");
}

/// A malformed op name must be a protocol error rather than a silent no-op, so
/// the frontend's error callback fires instead of the operation hanging.
#[test]
fn an_unknown_op_is_reported_as_an_error_against_the_request_id() {
    let events = run_daemon(&[json!({
        "type": "fs_op", "id": 11, "op": "shred", "src": "/tmp/x", "dst": "/tmp/y",
    })]);
    assert_eq!(events[0]["type"], "error");
    assert_eq!(events[0]["id"], 11);
}

/// fs_op shares the active-request table with listing, so `cancel` has to reach
/// it; without that a mistaken paste of a huge tree could not be stopped.
#[test]
fn a_cancelled_fs_op_never_reports_completion() {
    let directory = tempdir().expect("temporary directory");
    let src = directory.path().join("tree");
    std::fs::create_dir_all(src.join("nested")).expect("fixture");
    for index in 0..200 {
        std::fs::write(src.join(format!("nested/f{index}")), b"payload").expect("fixture");
    }
    let dst = directory.path().join("copy");

    let mut session = Session::start();
    session.send(&json!({
        "type": "fs_op", "id": 5, "op": "copy", "src": src, "dst": dst,
    }));
    session.send(&json!({"type": "cancel", "id": 5}));
    // A ping issued after the cancel must come back; if the daemon answers it
    // without an fs_op_done in between, the cancelled operation stayed silent.
    session.send(&json!({"type": "ping", "id": 6}));
    let event = session.next_event();
    assert_eq!(
        event["type"], "pong",
        "cancelled fs_op reported a result: {event}"
    );
    session.finish();
}
