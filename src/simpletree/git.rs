use anyhow::{Context, Result, bail};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

const CACHE_TTL: Duration = Duration::from_secs(5);
/// Repos with more dirty paths than this get truncated with a warning so a
/// single pathological worktree cannot flood the protocol stream.
pub const MAX_STATUS_ENTRIES: usize = 20_000;
/// How far below a non-repository root to look for repositories.  `~/projects`
/// needs 1 and `~/work/<client>/<repo>` needs 2; past that the walk costs more
/// than the marks are worth, and a tree rooted that far above its code has
/// bigger problems.
const MAX_REPO_SCAN_DEPTH: usize = 3;
/// Upper bound on repositories covered by one request, so a directory of
/// hundreds of checkouts cannot turn one keystroke into hundreds of processes.
const MAX_REPOS: usize = 32;

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

/// A prefixed status is not the repository's full status, so the prefix has to
/// be part of the key or a scoped run would answer an unscoped request.
type CacheKey = (PathBuf, Option<String>);

#[derive(Clone, Default)]
pub struct GitCache {
    repos: Arc<Mutex<HashMap<CacheKey, CachedStatus>>>,
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

    fn fresh(&self, key: &CacheKey) -> Option<(Arc<StatusMap>, bool)> {
        let repos = self.repos.lock().ok()?;
        let cached = repos.get(key)?;
        if cached.dirty || cached.taken_at.elapsed() > CACHE_TTL {
            return None;
        }
        Some((cached.statuses.clone(), cached.truncated))
    }

    fn store(&self, key: CacheKey, statuses: Arc<StatusMap>, truncated: bool) {
        if let Ok(mut repos) = self.repos.lock() {
            repos.insert(
                key,
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

/// Is this directory the root of a real repository?
///
/// The presence of a `.git` entry is not enough.  An empty `.git` directory —
/// left behind by a failed clone, or sitting in a shared /tmp — makes every
/// status query for everything below it fail with git's own confusing "not a
/// git repository" message, which is reported against the *tree root* the user
/// asked about rather than against the stray directory that caused it.
/// Requiring HEAD costs one stat and removes that entire class of report.
fn is_repository(dir: &Path) -> bool {
    let marker = dir.join(".git");
    match std::fs::metadata(&marker) {
        // A linked worktree or a submodule stores a `gitdir:` pointer file.
        Ok(meta) if meta.is_file() => true,
        Ok(meta) if meta.is_dir() => marker.join("HEAD").exists(),
        _ => false,
    }
}

/// Walk upward looking for a repository root (worktrees use a `.git` file).
pub fn resolve_repo_root(path: &Path) -> Option<PathBuf> {
    let mut current = Some(path);
    while let Some(dir) = current {
        if is_repository(dir) {
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

/// One unit of status work: a repository, plus the repo-relative directory to
/// restrict the run to.  The prefix is what makes a monorepo affordable — a
/// tree rooted at `<huge-repo>/services/api` asks about `services/api`, not
/// about the other ten thousand files, on every single save.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RepoScope {
    pub repo_root: PathBuf,
    pub prefix: Option<String>,
}

/// Every repository whose status is relevant to a tree rooted at `path`.
///
/// `resolve_repo_root` only ever walked *upward*, so a tree rooted at a
/// directory of checkouts (`~/projects`, `~/work`, any non-git container)
/// resolved to nothing and never showed a single mark.  When the upward walk
/// finds nothing, look down instead: a bounded walk that stops descending as
/// soon as it finds a repository, because a repository's own subdirectories are
/// covered by its status run.
pub fn discover_repos(path: &Path) -> Vec<RepoScope> {
    if let Some(repo_root) = resolve_repo_root(path) {
        let prefix = path
            .strip_prefix(&repo_root)
            .ok()
            .map(|rel| rel.to_string_lossy().into_owned())
            .filter(|rel| !rel.is_empty());
        return vec![RepoScope { repo_root, prefix }];
    }

    let mut found = Vec::new();
    let mut frontier = vec![(path.to_path_buf(), 0_usize)];
    while let Some((dir, depth)) = frontier.pop() {
        if found.len() >= MAX_REPOS || depth > MAX_REPO_SCAN_DEPTH {
            continue;
        }
        let Ok(entries) = std::fs::read_dir(&dir) else {
            continue;
        };
        for entry in entries.flatten() {
            if found.len() >= MAX_REPOS {
                break;
            }
            let name = entry.file_name();
            // Hidden directories are not where checkouts live, and descending
            // into `.git` itself would be both useless and enormous.
            if name.to_string_lossy().starts_with('.') {
                continue;
            }
            // `file_type` does not follow links; a link into a repo elsewhere
            // would make the walk unbounded and duplicate another root.
            if !entry.file_type().is_ok_and(|kind| kind.is_dir()) {
                continue;
            }
            let child = entry.path();
            if is_repository(&child) {
                found.push(RepoScope {
                    repo_root: child,
                    prefix: None,
                });
            } else {
                frontier.push((child, depth + 1));
            }
        }
    }
    found.sort_by(|left, right| left.repo_root.cmp(&right.repo_root));
    found
}

pub async fn repo_status(cache: &GitCache, scope: &RepoScope, force: bool) -> Result<RepoStatus> {
    let repo_root = scope.repo_root.clone();
    let key: CacheKey = (repo_root.clone(), scope.prefix.clone());

    if !force && let Some((statuses, truncated)) = cache.fresh(&key) {
        return Ok(RepoStatus {
            repo_root,
            statuses,
            truncated,
        });
    }

    // --no-optional-locks is a global git option and must precede the
    // subcommand; it keeps status runs from contending on index locks.
    let mut command = tokio::process::Command::new("git");
    command
        .arg("--no-optional-locks")
        .arg("-C")
        .arg(&repo_root)
        // -uall lists files inside untracked directories so every visible
        // node can carry its own mark; MAX_STATUS_ENTRIES caps the flood.
        .args(["status", "--porcelain=v2", "-z", "--untracked-files=all"]);
    if let Some(prefix) = &scope.prefix {
        command.arg("--").arg(prefix);
    }
    let output = command.output().await.context("failed to run git status")?;
    if !output.status.success() {
        bail!(
            "git status failed: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        );
    }

    let (statuses, truncated) = parse_porcelain_v2(&output.stdout, &repo_root);
    let statuses = Arc::new(statuses);
    cache.store(key, statuses.clone(), truncated);
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
    fn a_bare_dot_git_directory_is_not_a_repository() {
        let directory = tempfile::tempdir().unwrap();
        let stray = directory.path().join("stray");
        std::fs::create_dir_all(stray.join(".git")).unwrap();
        assert!(
            !is_repository(&stray),
            "an empty .git directory must not be mistaken for a repository"
        );

        std::fs::write(stray.join(".git/HEAD"), b"ref: refs/heads/main\n").unwrap();
        assert!(is_repository(&stray));

        let linked = directory.path().join("linked");
        std::fs::create_dir_all(&linked).unwrap();
        std::fs::write(linked.join(".git"), b"gitdir: /elsewhere\n").unwrap();
        assert!(
            is_repository(&linked),
            "a worktree pointer file is a repository"
        );
    }

    #[test]
    fn discovery_finds_every_repository_below_a_plain_container() {
        let directory = tempfile::tempdir().unwrap();
        let container = directory.path().join("projects");
        for name in ["alpha", "nested/beta"] {
            let repo = container.join(name).join(".git");
            std::fs::create_dir_all(&repo).unwrap();
            std::fs::write(repo.join("HEAD"), b"ref: refs/heads/main\n").unwrap();
        }
        // A repository's own subdirectories are covered by its status run, so
        // the walk must not descend into one and report it twice.
        std::fs::create_dir_all(container.join("alpha/sub/.git")).unwrap();
        std::fs::write(
            container.join("alpha/sub/.git/HEAD"),
            b"ref: refs/heads/main\n",
        )
        .unwrap();

        let found = discover_repos(&container);
        let roots: Vec<PathBuf> = found.iter().map(|scope| scope.repo_root.clone()).collect();
        assert_eq!(
            roots,
            vec![container.join("alpha"), container.join("nested/beta")]
        );
        assert!(found.iter().all(|scope| scope.prefix.is_none()));
    }

    #[test]
    fn a_root_below_a_repository_carries_its_relative_prefix() {
        let directory = tempfile::tempdir().unwrap();
        let repo = directory.path().join("repo");
        std::fs::create_dir_all(repo.join(".git")).unwrap();
        std::fs::write(repo.join(".git/HEAD"), b"ref: refs/heads/main\n").unwrap();
        std::fs::create_dir_all(repo.join("services/api")).unwrap();

        let found = discover_repos(&repo.join("services/api"));
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].repo_root, repo);
        assert_eq!(found[0].prefix.as_deref(), Some("services/api"));

        // At the repository root there is nothing to scope to.
        assert_eq!(discover_repos(&repo)[0].prefix, None);
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
