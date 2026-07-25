use anyhow::{Context, Result, bail};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

const CACHE_TTL: Duration = Duration::from_secs(5);
/// Repos with more dirty paths than this get truncated with a warning so a
/// single pathological worktree cannot flood the protocol stream.
pub const MAX_STATUS_ENTRIES: usize = 20_000;

/// Per-file and aggregated per-directory status codes, keyed by absolute path.
/// Codes: C conflict, M worktree-modified, S staged, U untracked, D deleted.
/// A file can carry two codes ("SM"); consumers render the first.
pub type StatusMap = HashMap<String, String>;

struct CachedStatus {
    statuses: Arc<StatusMap>,
    truncated: bool,
    taken_at: Instant,
    dirty: bool,
}

#[derive(Clone, Default)]
pub struct GitCache {
    repos: Arc<Mutex<HashMap<PathBuf, CachedStatus>>>,
}

impl GitCache {
    /// Called from the fs-event debouncer: any filesystem change invalidates
    /// cached status for every repo. Coarse, but status runs are cheap and
    /// debounced, and correctness beats precision here.
    pub fn mark_all_dirty(&self) {
        if let Ok(mut repos) = self.repos.lock() {
            for cached in repos.values_mut() {
                cached.dirty = true;
            }
        }
    }

    fn fresh(&self, repo_root: &Path) -> Option<(Arc<StatusMap>, bool)> {
        let repos = self.repos.lock().ok()?;
        let cached = repos.get(repo_root)?;
        if cached.dirty || cached.taken_at.elapsed() > CACHE_TTL {
            return None;
        }
        Some((cached.statuses.clone(), cached.truncated))
    }

    fn store(&self, repo_root: PathBuf, statuses: Arc<StatusMap>, truncated: bool) {
        if let Ok(mut repos) = self.repos.lock() {
            repos.insert(
                repo_root,
                CachedStatus {
                    statuses,
                    truncated,
                    taken_at: Instant::now(),
                    dirty: false,
                },
            );
        }
    }
}

/// Probe once at startup; "git-status" is only advertised when this succeeds.
pub fn git_available() -> bool {
    std::process::Command::new("git")
        .arg("--version")
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .is_ok_and(|status| status.success())
}

/// Walk upward looking for a `.git` directory or file (worktrees use a file).
pub fn resolve_repo_root(path: &Path) -> Option<PathBuf> {
    let mut current = Some(path);
    while let Some(dir) = current {
        if dir.join(".git").exists() {
            return Some(dir.to_path_buf());
        }
        current = dir.parent();
    }
    None
}

pub struct RepoStatus {
    pub repo_root: PathBuf,
    pub statuses: Arc<StatusMap>,
    pub truncated: bool,
}

pub async fn repo_status(cache: &GitCache, path: &Path, force: bool) -> Result<RepoStatus> {
    let Some(repo_root) = resolve_repo_root(path) else {
        bail!("not inside a git repository: {}", path.display());
    };

    if !force {
        if let Some((statuses, truncated)) = cache.fresh(&repo_root) {
            return Ok(RepoStatus {
                repo_root,
                statuses,
                truncated,
            });
        }
    }

    // --no-optional-locks is a global git option and must precede the
    // subcommand; it keeps status runs from contending on index locks.
    let output = tokio::process::Command::new("git")
        .arg("--no-optional-locks")
        .arg("-C")
        .arg(&repo_root)
        // -uall lists files inside untracked directories so every visible
        // node can carry its own mark; MAX_STATUS_ENTRIES caps the flood.
        .args(["status", "--porcelain=v2", "-z", "--untracked-files=all"])
        .output()
        .await
        .context("failed to run git status")?;
    if !output.status.success() {
        bail!(
            "git status failed: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        );
    }

    let (statuses, truncated) = parse_porcelain_v2(&output.stdout, &repo_root);
    let statuses = Arc::new(statuses);
    cache.store(repo_root.clone(), statuses.clone(), truncated);
    Ok(RepoStatus {
        repo_root,
        statuses,
        truncated,
    })
}

/// Parse NUL-separated porcelain v2 records into per-file codes, then
/// aggregate every ancestor directory up to the repo root.
fn parse_porcelain_v2(stdout: &[u8], repo_root: &Path) -> (StatusMap, bool) {
    let mut statuses = StatusMap::new();
    let mut truncated = false;

    let mut records = stdout.split(|byte| *byte == 0).peekable();
    while let Some(record) = records.next() {
        if statuses.len() >= MAX_STATUS_ENTRIES {
            truncated = true;
            break;
        }
        let record = String::from_utf8_lossy(record);
        let Some((code, rel_path)) = parse_record(&record) else {
            continue;
        };
        // Rename records ("2") are followed by the original path in a
        // separate NUL field; it belongs to this record, not the next one.
        if record.starts_with("2 ") {
            records.next();
        }
        // Untracked directories arrive as "dir/"; keys must not carry the
        // trailing slash or the Vim side cannot match its node paths.
        let abs = repo_root.join(rel_path.trim_end_matches('/'));
        statuses.insert(abs.to_string_lossy().into_owned(), code);
    }

    aggregate_directories(&mut statuses, repo_root);
    (statuses, truncated)
}

/// Returns (code, relative path) for one porcelain v2 record.
fn parse_record(record: &str) -> Option<(String, &str)> {
    let mut fields = record.split(' ');
    match fields.next()? {
        "?" => Some(("U".to_owned(), record.get(2..)?)),
        "u" => {
            // u <XY> <sub> <m1..m3> <mW> <h1> <h2> <h3> <path>
            let path = record.splitn(11, ' ').nth(10)?;
            Some(("C".to_owned(), path))
        }
        kind @ ("1" | "2") => {
            let xy = fields.next()?;
            let mut chars = xy.chars();
            let index = chars.next()?;
            let worktree = chars.next()?;
            let mut code = String::new();
            if index != '.' {
                code.push('S');
            }
            match worktree {
                '.' => {}
                'D' => code.push('D'),
                _ => code.push('M'),
            }
            if code.is_empty() {
                return None;
            }
            let field_count = if kind == "1" { 9 } else { 10 };
            let path = record.splitn(field_count, ' ').nth(field_count - 1)?;
            Some((code, path))
        }
        _ => None,
    }
}

fn code_priority(code: &str) -> u8 {
    if code.contains('C') {
        4
    } else if code.contains('M') || code.contains('D') {
        3
    } else if code.contains('S') {
        2
    } else {
        1
    }
}

fn priority_code(priority: u8) -> &'static str {
    match priority {
        4 => "C",
        3 => "M",
        2 => "S",
        _ => "U",
    }
}

fn aggregate_directories(statuses: &mut StatusMap, repo_root: &Path) {
    let mut dir_priority: HashMap<PathBuf, u8> = HashMap::new();
    for (path, code) in statuses.iter() {
        let priority = code_priority(code);
        let mut current = Path::new(path).parent();
        while let Some(dir) = current {
            let slot = dir_priority.entry(dir.to_path_buf()).or_insert(0);
            if *slot < priority {
                *slot = priority;
            }
            if dir == repo_root {
                break;
            }
            current = dir.parent();
        }
    }
    for (dir, priority) in dir_priority {
        statuses
            .entry(dir.to_string_lossy().into_owned())
            .or_insert_with(|| priority_code(priority).to_owned());
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn porcelain_records_map_to_codes() {
        assert_eq!(parse_record("? new.txt"), Some(("U".to_owned(), "new.txt")));
        assert_eq!(
            parse_record("1 .M N... 100644 100644 100644 abc def src/main.rs"),
            Some(("M".to_owned(), "src/main.rs"))
        );
        assert_eq!(
            parse_record("1 M. N... 100644 100644 100644 abc def staged.rs"),
            Some(("S".to_owned(), "staged.rs"))
        );
        assert_eq!(
            parse_record("1 MM N... 100644 100644 100644 abc def both.rs"),
            Some(("SM".to_owned(), "both.rs"))
        );
        assert_eq!(
            parse_record("1 .D N... 100644 100644 000000 abc def gone.rs"),
            Some(("D".to_owned(), "gone.rs"))
        );
        assert_eq!(
            parse_record("u UU N... 100644 100644 100644 100644 a b c conflict.rs"),
            Some(("C".to_owned(), "conflict.rs"))
        );
        // Clean XY is not a status.
        assert_eq!(
            parse_record("1 .. N... 100644 100644 100644 abc def clean.rs"),
            None
        );
    }

    #[test]
    fn record_paths_may_contain_spaces() {
        assert_eq!(
            parse_record("1 .M N... 100644 100644 100644 abc def a name with spaces.txt"),
            Some(("M".to_owned(), "a name with spaces.txt"))
        );
        assert_eq!(
            parse_record("? spaced dir/file name.txt"),
            Some(("U".to_owned(), "spaced dir/file name.txt"))
        );
    }

    #[test]
    fn directories_aggregate_the_highest_priority_status() {
        let repo = Path::new("/repo");
        let mut statuses = StatusMap::new();
        statuses.insert("/repo/src/deep/mod.rs".to_owned(), "M".to_owned());
        statuses.insert("/repo/src/other.rs".to_owned(), "U".to_owned());
        statuses.insert("/repo/docs/x.md".to_owned(), "C".to_owned());
        aggregate_directories(&mut statuses, repo);

        assert_eq!(
            statuses.get("/repo/src/deep").map(String::as_str),
            Some("M")
        );
        assert_eq!(statuses.get("/repo/src").map(String::as_str), Some("M"));
        assert_eq!(statuses.get("/repo/docs").map(String::as_str), Some("C"));
        assert_eq!(statuses.get("/repo").map(String::as_str), Some("C"));
    }

    #[test]
    fn aggregation_stops_at_the_repo_root() {
        let repo = Path::new("/repo");
        let mut statuses = StatusMap::new();
        statuses.insert("/repo/a.txt".to_owned(), "M".to_owned());
        aggregate_directories(&mut statuses, repo);

        assert_eq!(statuses.get("/repo").map(String::as_str), Some("M"));
        assert!(!statuses.contains_key("/"));
    }
}
