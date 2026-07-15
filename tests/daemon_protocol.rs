use serde_json::{Value, json};
use std::{
    fs::File,
    io::Write,
    path::Path,
    process::{Command, Stdio},
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

fn list_request(id: u64, path: &Path, page: usize) -> Value {
    list_request_with_flags(id, path, page, true, false)
}

fn list_request_with_flags(
    id: u64,
    path: &Path,
    page: usize,
    show_hidden: bool,
    git_ignore: bool,
) -> Value {
    json!({
        "type": "list",
        "id": id,
        "path": path,
        "show_hidden": show_hidden,
        "git_ignore": git_ignore,
        "max": page,
    })
}

fn event_names(events: &[Value], id: u64) -> Vec<&str> {
    events
        .iter()
        .filter(|event| event["id"] == id)
        .flat_map(|event| event["entries"].as_array().expect("entries"))
        .map(|entry| entry["name"].as_str().expect("entry name"))
        .collect()
}

#[test]
fn zero_page_is_clamped_and_eof_drains_every_chunk() {
    let directory = tempdir().expect("temporary directory");
    for name in ["c", "a", "b"] {
        File::create(directory.path().join(name)).expect("create fixture");
    }

    let events = run_daemon(&[list_request(1, directory.path(), 0)]);
    assert_eq!(events.len(), 3);

    let names: Vec<_> = events
        .iter()
        .flat_map(|event| event["entries"].as_array().expect("entries"))
        .map(|entry| entry["name"].as_str().expect("entry name"))
        .collect();
    assert_eq!(names, ["a", "b", "c"]);
    assert_eq!(events[0]["done"], false);
    assert_eq!(events[1]["done"], false);
    assert_eq!(events[2]["done"], true);
}

#[test]
fn empty_directory_emits_one_final_chunk() {
    let directory = tempdir().expect("temporary directory");
    let events = run_daemon(&[list_request(2, directory.path(), 10)]);
    assert_eq!(events.len(), 1);
    assert_eq!(events[0]["type"], "list_chunk");
    assert_eq!(events[0]["entries"], json!([]));
    assert_eq!(events[0]["done"], true);
}

#[test]
fn nonexistent_and_file_roots_return_correlated_errors() {
    let directory = tempdir().expect("temporary directory");
    let file = directory.path().join("plain-file");
    File::create(&file).expect("create fixture");
    let missing = directory.path().join("missing");

    let events = run_daemon(&[list_request(10, &missing, 10), list_request(11, &file, 10)]);
    assert_eq!(events.len(), 2);

    let missing_error = events
        .iter()
        .find(|event| event["id"] == 10)
        .expect("missing-path error");
    assert_eq!(missing_error["type"], "error");
    assert!(
        missing_error["message"]
            .as_str()
            .expect("error message")
            .contains("failed to inspect directory")
    );

    let file_error = events
        .iter()
        .find(|event| event["id"] == 11)
        .expect("file-path error");
    assert_eq!(file_error["type"], "error");
    assert!(
        file_error["message"]
            .as_str()
            .expect("error message")
            .contains("not a directory")
    );
}

#[test]
fn malformed_request_preserves_a_valid_id() {
    let events = run_daemon(&[json!({
        "type": "list",
        "id": 77,
        "path": 123,
    })]);

    assert_eq!(events.len(), 1);
    assert_eq!(events[0]["type"], "error");
    assert_eq!(events[0]["id"], 77);
}

#[test]
fn reusing_an_active_id_supersedes_the_old_request() {
    let old_directory = tempdir().expect("old temporary directory");
    for index in 0..1_000 {
        File::create(old_directory.path().join(format!("old-{index:04}")))
            .expect("create old fixture");
    }
    let new_directory = tempdir().expect("new temporary directory");
    File::create(new_directory.path().join("new-result")).expect("create new fixture");

    let events = run_daemon(&[
        list_request(42, old_directory.path(), 1),
        list_request(42, new_directory.path(), 1),
    ]);
    assert_eq!(events.len(), 1);
    assert_eq!(events[0]["type"], "list_chunk");
    assert_eq!(events[0]["id"], 42);
    assert_eq!(events[0]["entries"][0]["name"], "new-result");
    assert_eq!(events[0]["done"], true);
}

#[test]
fn hidden_and_git_ignore_flags_are_independent() {
    let directory = tempdir().expect("temporary directory");
    std::fs::create_dir(directory.path().join(".git")).expect("create .git marker");
    std::fs::write(directory.path().join(".gitignore"), "ignored.log\n")
        .expect("write ignore file");
    for name in ["visible.txt", ".hidden.txt", "ignored.log"] {
        File::create(directory.path().join(name)).expect("create fixture");
    }

    let events = run_daemon(&[
        list_request_with_flags(51, directory.path(), 100, false, true),
        list_request_with_flags(52, directory.path(), 100, true, true),
        list_request_with_flags(53, directory.path(), 100, true, false),
    ]);

    let hidden_filtered = event_names(&events, 51);
    assert!(hidden_filtered.contains(&"visible.txt"));
    assert!(!hidden_filtered.contains(&".hidden.txt"));
    assert!(!hidden_filtered.contains(&"ignored.log"));

    let hidden_visible = event_names(&events, 52);
    assert!(hidden_visible.contains(&".hidden.txt"));
    assert!(!hidden_visible.contains(&"ignored.log"));

    let ignores_disabled = event_names(&events, 53);
    assert!(ignores_disabled.contains(&".hidden.txt"));
    assert!(ignores_disabled.contains(&"ignored.log"));
}

#[cfg(unix)]
#[test]
fn symlinked_directories_are_expandable_without_recursive_following() {
    use std::os::unix::fs::symlink;

    let directory = tempdir().expect("temporary directory");
    let real = directory.path().join("real");
    std::fs::create_dir(&real).expect("create real directory");
    File::create(real.join("child.txt")).expect("create child");
    let link = directory.path().join("link");
    symlink("real", &link).expect("create symlink");

    let events = run_daemon(&[
        list_request(61, directory.path(), 100),
        list_request(62, &link, 100),
    ]);
    let link_entry = events
        .iter()
        .filter(|event| event["id"] == 61)
        .flat_map(|event| event["entries"].as_array().expect("entries"))
        .find(|entry| entry["name"] == "link")
        .expect("link entry");
    assert_eq!(link_entry["is_dir"], true);
    assert_eq!(event_names(&events, 62), ["child.txt"]);
}
