//! git status across more than one repository under one tree root, and the
//! pathspec that keeps a monorepo affordable.
//!
//! `resolve_repo_root()` only ever walked upward, so a tree rooted at a
//! directory of checkouts (`~/projects`, `~/work`, any non-git container)
//! resolved to nothing and showed no marks anywhere — with no error the user
//! could see.

use serde_json::{Value, json};
use std::{
    io::Write,
    path::Path,
    process::{Command, Stdio},
};
use tempfile::tempdir;

fn git_available() -> bool {
    Command::new("git")
        .arg("--version")
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .is_ok_and(|status| status.success())
}

fn git(root: &Path, args: &[&str]) {
    let status = Command::new("git")
        .arg("-C")
        .arg(root)
        .args(args)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .expect("run git");
    assert!(
        status.success(),
        "git {args:?} failed in {}",
        root.display()
    );
}

fn init_repo(root: &Path) {
    std::fs::create_dir_all(root).expect("fixture");
    git(root, &["init", "-q"]);
    git(
        root,
        &[
            "-c",
            "user.email=t@t",
            "-c",
            "user.name=t",
            "commit",
            "-q",
            "--allow-empty",
            "-m",
            "init",
        ],
    );
}

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

#[test]
fn a_directory_of_repositories_reports_every_one_of_them() {
    if !git_available() {
        return;
    }
    let directory = tempdir().expect("temporary directory");
    let container = directory.path();
    init_repo(&container.join("alpha"));
    init_repo(&container.join("beta"));
    std::fs::write(container.join("alpha/dirty.txt"), b"a").expect("fixture");
    std::fs::write(container.join("beta/dirty.txt"), b"b").expect("fixture");
    // A loose file directly under the container belongs to no repository and
    // must not acquire a mark from either of them.
    std::fs::write(container.join("loose.txt"), b"c").expect("fixture");

    let events = run_daemon(&[json!({
        "type": "git_status", "id": 1, "path": container,
    })]);
    let statuses: Vec<&Value> = events
        .iter()
        .filter(|event| event["type"] == "git_status")
        .collect();
    assert_eq!(statuses.len(), 2, "expected one event per repo: {events:?}");
    assert_eq!(statuses[0]["done"], false, "only the last event is done");
    assert_eq!(statuses[1]["done"], true);

    let mut roots: Vec<String> = statuses
        .iter()
        .map(|event| event["repo_root"].as_str().expect("repo_root").to_owned())
        .collect();
    roots.sort();
    assert_eq!(
        roots,
        vec![
            container.join("alpha").to_string_lossy().into_owned(),
            container.join("beta").to_string_lossy().into_owned(),
        ]
    );

    let marked = |path: &Path| {
        statuses.iter().any(|event| {
            event["statuses"]
                .get(path.to_string_lossy().as_ref())
                .is_some()
        })
    };
    assert!(marked(&container.join("alpha/dirty.txt")));
    assert!(marked(&container.join("beta/dirty.txt")));
    assert!(!marked(&container.join("loose.txt")));
}

/// The two repositories' maps must be disjoint, because the frontend merges
/// them into one dict; an overlapping key would mean one repo silently
/// overwriting the other's marks.
#[test]
fn per_repository_maps_do_not_overlap() {
    if !git_available() {
        return;
    }
    let directory = tempdir().expect("temporary directory");
    let container = directory.path();
    init_repo(&container.join("alpha"));
    init_repo(&container.join("beta"));
    std::fs::write(container.join("alpha/x.txt"), b"a").expect("fixture");
    std::fs::write(container.join("beta/x.txt"), b"b").expect("fixture");

    let events = run_daemon(&[json!({"type": "git_status", "id": 1, "path": container})]);
    let maps: Vec<&serde_json::Map<String, Value>> = events
        .iter()
        .filter(|event| event["type"] == "git_status")
        .map(|event| event["statuses"].as_object().expect("status map"))
        .collect();
    assert_eq!(maps.len(), 2);
    for key in maps[0].keys() {
        assert!(!maps[1].contains_key(key), "repos both claimed {key}");
    }
}

/// A tree rooted inside a large repository asks about its own subtree only.
/// Without the pathspec every save re-runs status over the whole worktree and
/// ships the entire map.
#[test]
fn a_root_inside_a_repository_is_scoped_to_its_subtree() {
    if !git_available() {
        return;
    }
    let directory = tempdir().expect("temporary directory");
    let repo = directory.path();
    init_repo(repo);
    std::fs::create_dir_all(repo.join("services/api")).expect("fixture");
    std::fs::create_dir_all(repo.join("elsewhere")).expect("fixture");
    std::fs::write(repo.join("services/api/handler.rs"), b"x").expect("fixture");
    std::fs::write(repo.join("elsewhere/unrelated.rs"), b"x").expect("fixture");

    let events = run_daemon(&[json!({
        "type": "git_status", "id": 1, "path": repo.join("services/api"),
    })]);
    let status = events
        .iter()
        .find(|event| event["type"] == "git_status")
        .expect("git_status event");
    assert_eq!(status["repo_root"], repo.to_string_lossy().as_ref());
    let map = status["statuses"].as_object().expect("status map");
    assert!(
        map.contains_key(
            repo.join("services/api/handler.rs")
                .to_string_lossy()
                .as_ref()
        ),
        "the scoped run lost its own subtree: {map:?}"
    );
    assert!(
        !map.contains_key(
            repo.join("elsewhere/unrelated.rs")
                .to_string_lossy()
                .as_ref()
        ),
        "the run was not scoped to the tree root: {map:?}"
    );
}

#[test]
fn a_root_with_no_repository_anywhere_reports_an_error() {
    let directory = tempdir().expect("temporary directory");
    std::fs::create_dir_all(directory.path().join("plain/nested")).expect("fixture");

    let events = run_daemon(&[json!({
        "type": "git_status", "id": 4, "path": directory.path(),
    })]);
    assert_eq!(events[0]["type"], "error");
    assert_eq!(events[0]["id"], 4);
    assert!(
        events[0]["message"]
            .as_str()
            .expect("message")
            .contains("not inside a git repository")
    );
}
