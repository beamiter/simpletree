use serde::{Deserialize, Serialize};

pub const DEFAULT_PAGE_SIZE: usize = 200;
pub const MAX_PAGE_SIZE: usize = 1_000;
pub const MAX_ACTIVE_REQUESTS: usize = 64;
pub const MAX_CONCURRENT_SCANS: usize = 8;
pub const OUTPUT_CHANNEL_CAPACITY: usize = 64;
pub const PROTOCOL_VERSION: u32 = 2;

/// Capabilities that do not depend on runtime probing.
pub const BASE_CAPABILITIES: &[&str] = &[
    "list",
    "cancel",
    "ping",
    "chunked-results",
    "git-ignore",
    "hidden-files",
    "metadata",
    "warnings",
];

#[derive(Debug, Deserialize)]
#[serde(tag = "type")]
pub enum Request {
    #[serde(rename = "list", alias = "expand")]
    List {
        id: u64,
        path: String,
        #[serde(default)]
        show_hidden: bool,
        #[serde(default = "default_git_ignore")]
        git_ignore: bool,
        #[serde(default = "default_page")]
        max: usize,
        #[serde(default)]
        meta: bool,
    },
    #[serde(rename = "cancel")]
    Cancel { id: u64 },
    #[serde(rename = "ping")]
    Ping { id: u64 },
    #[serde(rename = "watch")]
    Watch { id: u64, path: String },
    #[serde(rename = "unwatch")]
    Unwatch { id: u64, path: String },
    #[serde(rename = "git_status")]
    GitStatus {
        id: u64,
        path: String,
        #[serde(default)]
        force: bool,
    },
    /// Copy / move / remove performed by the daemon instead of by Vimscript.
    /// The frontend has already applied every policy check that depends on
    /// editor state; this carries only the approved pair. `remove` ignores
    /// `dst`, which may then be omitted.
    #[serde(rename = "fs_op")]
    FsOp {
        id: u64,
        op: crate::fsops::FsOpKind,
        src: String,
        #[serde(default)]
        dst: String,
    },
    #[serde(rename = "search")]
    Search {
        id: u64,
        root: String,
        query: String,
        #[serde(default)]
        mode: crate::search::SearchMode,
        #[serde(default)]
        max_results: Option<usize>,
        #[serde(default)]
        show_hidden: bool,
        #[serde(default = "default_git_ignore")]
        git_ignore: bool,
    },
}

fn default_page() -> usize {
    DEFAULT_PAGE_SIZE
}

fn default_git_ignore() -> bool {
    true
}

pub fn normalize_page(page: usize) -> usize {
    page.clamp(1, MAX_PAGE_SIZE)
}

#[derive(Debug, Serialize)]
#[serde(tag = "type")]
#[allow(clippy::enum_variant_names)]
pub enum Event {
    #[serde(rename = "list_chunk")]
    ListChunk {
        id: u64,
        entries: Vec<Entry>,
        done: bool,
        #[serde(skip_serializing_if = "Vec::is_empty")]
        warnings: Vec<String>,
    },
    #[serde(rename = "error")]
    Error { id: u64, message: String },
    #[serde(rename = "ok")]
    Ok { id: u64 },
    #[serde(rename = "fs_event")]
    FsEvent { dirs: Vec<String> },
    #[serde(rename = "git_status")]
    GitStatus {
        id: u64,
        repo_root: String,
        statuses: std::collections::HashMap<String, String>,
        done: bool,
        #[serde(skip_serializing_if = "std::ops::Not::not")]
        truncated: bool,
    },
    #[serde(rename = "search_chunk")]
    SearchChunk {
        id: u64,
        entries: Vec<Entry>,
        done: bool,
    },
    /// Result of an `fs_op`. Flattened so the frontend reads the same field
    /// names its own synchronous helpers already return.
    #[serde(rename = "fs_op_done")]
    FsOpDone {
        id: u64,
        #[serde(flatten)]
        outcome: crate::fsops::FsOpOutcome,
    },
    #[serde(rename = "pong")]
    Pong {
        id: u64,
        protocol_version: u32,
        daemon_version: &'static str,
        capabilities: Vec<&'static str>,
    },
}

#[derive(Debug, Clone, Serialize)]
pub struct Entry {
    pub name: String,
    pub path: String,
    pub is_dir: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub size: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub mtime: Option<i64>,
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    pub is_symlink: bool,
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    pub non_utf8: bool,
}

impl Entry {
    pub fn new(name: String, path: String, is_dir: bool) -> Self {
        Entry {
            name,
            path,
            is_dir,
            size: None,
            mtime: None,
            is_symlink: false,
            non_utf8: false,
        }
    }
}

pub fn best_effort_request_id(line: &str) -> u64 {
    serde_json::from_str::<serde_json::Value>(line)
        .ok()
        .and_then(|value| value.get("id").and_then(serde_json::Value::as_u64))
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn page_size_is_always_bounded_and_nonzero() {
        assert_eq!(normalize_page(0), 1);
        assert_eq!(normalize_page(1), 1);
        assert_eq!(normalize_page(DEFAULT_PAGE_SIZE), DEFAULT_PAGE_SIZE);
        assert_eq!(normalize_page(usize::MAX), MAX_PAGE_SIZE);
    }

    #[test]
    fn base_capabilities_include_the_core_protocol_operations() {
        assert!(BASE_CAPABILITIES.contains(&"list"));
        assert!(BASE_CAPABILITIES.contains(&"cancel"));
        assert!(BASE_CAPABILITIES.contains(&"ping"));
        assert!(BASE_CAPABILITIES.contains(&"metadata"));
        assert!(BASE_CAPABILITIES.contains(&"warnings"));
    }

    #[test]
    fn optional_entry_fields_stay_off_the_wire_when_absent() {
        let plain = serde_json::to_string(&Entry::new("a".into(), "/tmp/a".into(), false)).unwrap();
        assert!(!plain.contains("size"));
        assert!(!plain.contains("mtime"));
        assert!(!plain.contains("is_symlink"));
        assert!(!plain.contains("non_utf8"));

        let mut rich = Entry::new("b".into(), "/tmp/b".into(), false);
        rich.size = Some(12);
        rich.mtime = Some(1_700_000_000);
        rich.is_symlink = true;
        rich.non_utf8 = true;
        let rich = serde_json::to_string(&rich).unwrap();
        assert!(rich.contains("\"size\":12"));
        assert!(rich.contains("\"mtime\":1700000000"));
        assert!(rich.contains("\"is_symlink\":true"));
        assert!(rich.contains("\"non_utf8\":true"));
    }

    #[test]
    fn warnings_stay_off_the_wire_when_empty() {
        let event = Event::ListChunk {
            id: 1,
            entries: Vec::new(),
            done: true,
            warnings: Vec::new(),
        };
        let line = serde_json::to_string(&event).unwrap();
        assert!(!line.contains("warnings"));
    }

    #[test]
    fn request_ids_are_recovered_from_malformed_lines() {
        assert_eq!(best_effort_request_id(r#"{"id":42,"type":"nope"}"#), 42);
        assert_eq!(best_effort_request_id("not json"), 0);
    }
}
