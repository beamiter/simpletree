use crate::git::GitCache;
use crate::protocol::Event;
use crate::scan::ScanCache;
use crate::server::{EventTx, send_event};
use anyhow::{Context, Result, bail};
use notify::{
    EventKind, RecommendedWatcher, RecursiveMode, Watcher,
    event::{AccessKind, AccessMode},
};
use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::sync::mpsc;
use tokio::time::{Instant, sleep, sleep_until};

pub const MAX_WATCHES: usize = 512;
const QUIET_WINDOW: Duration = Duration::from_millis(200);
const HARD_DEADLINE: Duration = Duration::from_millis(500);

type WatchedDirs = Arc<Mutex<HashSet<PathBuf>>>;

struct RawChange {
    dir: PathBuf,
    /// Root of the subtree whose effective ignore policy can change.
    ignore_scope: Option<PathBuf>,
}

fn listing_can_change(kind: EventKind) -> bool {
    // The daemon itself opens and reads the directories and ignore files it
    // watches. Forwarding those accesses indefinitely requeues its own scans.
    !matches!(kind, EventKind::Access(access) if access != AccessKind::Close(AccessMode::Write))
}

fn ignore_scope(path: &Path, dir: &Path) -> Option<PathBuf> {
    match path.file_name().and_then(|name| name.to_str()) {
        Some(".gitignore" | ".ignore") => Some(dir.to_path_buf()),
        Some("exclude") => {
            // Preserve invalidation for other files named exclude, while
            // recognizing the repository scope of a watched .git/info file.
            let scope = dir
                .parent()
                .filter(|git| dir.ends_with("info") && git.ends_with(".git"))
                .and_then(Path::parent)
                .unwrap_or(dir);
            Some(scope.to_path_buf())
        }
        _ => None,
    }
}

fn add_policy_watches(
    dirs: &mut HashSet<PathBuf>,
    scopes: &HashSet<PathBuf>,
    watched: &HashSet<PathBuf>,
) {
    if !scopes.is_empty() {
        dirs.extend(
            watched
                .iter()
                .filter(|dir| scopes.iter().any(|scope| dir.starts_with(scope)))
                .cloned(),
        );
    }
}

fn sorted_paths(paths: HashSet<PathBuf>) -> Vec<String> {
    let mut paths: Vec<_> = paths
        .into_iter()
        .map(|dir| dir.to_string_lossy().into_owned())
        .collect();
    paths.sort_unstable();
    paths
}

/// Non-recursive per-directory watcher. Raw notify events cross from the
/// notify callback thread into the runtime over an unbounded channel; the
/// debounce task coalesces them into one fs_event per quiet window.
pub struct WatchService {
    watcher: RecommendedWatcher,
    watched: WatchedDirs,
    scan_cache: ScanCache,
}

impl WatchService {
    /// Returns None when the platform watcher cannot be created; callers must
    /// then leave the "watch" capability unadvertised.
    pub fn start(out: EventTx, git_cache: GitCache, scan_cache: ScanCache) -> Option<WatchService> {
        let watched: WatchedDirs = Arc::new(Mutex::new(HashSet::new()));
        let (raw_tx, raw_rx) = mpsc::unbounded_channel::<RawChange>();

        let handler_watched = watched.clone();
        let watcher = notify::recommended_watcher(move |event: notify::Result<notify::Event>| {
            let Ok(event) = event else {
                return;
            };
            if !listing_can_change(event.kind) {
                return;
            }
            let Ok(watched) = handler_watched.lock() else {
                return;
            };
            for path in &event.paths {
                if let Some(dir) = owning_watched_dir(&watched, path) {
                    // Send failures mean the daemon is shutting down.
                    let _ = raw_tx.send(RawChange {
                        ignore_scope: ignore_scope(path, &dir),
                        dir,
                    });
                }
            }
        })
        .ok()?;

        tokio::spawn(debounce_fs_events(
            raw_rx,
            out,
            git_cache,
            scan_cache.clone(),
            watched.clone(),
        ));
        Some(WatchService {
            watcher,
            watched,
            scan_cache,
        })
    }

    pub fn watch(&mut self, path: &Path) -> Result<()> {
        {
            let watched = self.watched.lock().expect("watched set poisoned");
            if watched.contains(path) {
                return Ok(());
            }
            if watched.len() >= MAX_WATCHES {
                bail!("too many watched directories (limit {MAX_WATCHES})");
            }
        }
        self.watcher
            .watch(path, RecursiveMode::NonRecursive)
            .with_context(|| format!("failed to watch directory: {}", path.display()))?;
        self.watched
            .lock()
            .expect("watched set poisoned")
            .insert(path.to_path_buf());
        Ok(())
    }

    pub fn unwatch(&mut self, path: &Path) {
        let was_watched = self
            .watched
            .lock()
            .expect("watched set poisoned")
            .remove(path);
        if was_watched {
            // Unwatch after removal so late events for this path are dropped.
            let _ = self.watcher.unwatch(path);
        }
        // Without a watch there is no invalidation signal, so the cached
        // listing must go too.
        self.scan_cache.evict_dir(path);
    }

    pub fn is_watched(&self, path: &Path) -> bool {
        self.watched
            .lock()
            .expect("watched set poisoned")
            .contains(path)
    }
}

/// Map an event path to the watched directory it belongs to: the path itself
/// (directory-level events) or its parent (child create/remove/modify).
fn owning_watched_dir(watched: &HashSet<PathBuf>, path: &Path) -> Option<PathBuf> {
    if watched.contains(path) {
        return Some(path.to_path_buf());
    }
    let parent = path.parent()?;
    watched.contains(parent).then(|| parent.to_path_buf())
}

async fn debounce_fs_events(
    mut rx: mpsc::UnboundedReceiver<RawChange>,
    out: EventTx,
    git_cache: GitCache,
    scan_cache: ScanCache,
    watched: WatchedDirs,
) {
    while let Some(first) = rx.recv().await {
        let mut dirs: HashSet<PathBuf> = HashSet::new();
        let mut ignore_scopes: HashSet<_> = first.ignore_scope.into_iter().collect();
        dirs.insert(first.dir);
        let deadline = Instant::now() + HARD_DEADLINE;

        loop {
            tokio::select! {
                _ = sleep(QUIET_WINDOW) => break,
                _ = sleep_until(deadline) => break,
                more = rx.recv() => match more {
                    Some(change) => {
                        ignore_scopes.extend(change.ignore_scope);
                        dirs.insert(change.dir);
                    }
                    None => break,
                }
            }
        }

        if !ignore_scopes.is_empty() {
            scan_cache.clear();
        } else {
            for dir in &dirs {
                scan_cache.evict_dir(dir);
            }
        }
        // Any filesystem change may move git state; refresh on next query.
        git_cache.mark_all_dirty();

        // Keep active descendants in the existing field for older clients.
        // New clients also receive the roots to expire collapsed caches.
        if let Ok(watched) = watched.lock() {
            add_policy_watches(&mut dirs, &ignore_scopes, &watched);
        }
        if send_event(
            &out,
            &Event::FsEvent {
                dirs: sorted_paths(dirs),
                ignore_scopes: sorted_paths(ignore_scopes),
            },
        )
        .await
        .is_err()
        {
            return;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_do_not_refresh_but_write_closes_do() {
        assert!(!listing_can_change(EventKind::Access(AccessKind::Read)));
        assert!(!listing_can_change(EventKind::Access(AccessKind::Open(
            AccessMode::Any
        ))));
        assert!(!listing_can_change(EventKind::Access(AccessKind::Close(
            AccessMode::Read
        ))));
        assert!(listing_can_change(EventKind::Access(AccessKind::Close(
            AccessMode::Write
        ))));
        assert!(listing_can_change(EventKind::Modify(
            notify::event::ModifyKind::Any
        )));
    }

    #[test]
    fn ignore_changes_include_watched_descendants_but_not_siblings() {
        assert_eq!(
            ignore_scope(Path::new("/work/src/.gitignore"), Path::new("/work/src")),
            Some("/work/src".into())
        );
        assert_eq!(
            ignore_scope(
                Path::new("/work/.git/info/exclude"),
                Path::new("/work/.git/info")
            ),
            Some("/work".into())
        );
        assert_eq!(
            ignore_scope(Path::new("/work/src/main.rs"), Path::new("/work/src")),
            None
        );
        let mut dirs = HashSet::from([PathBuf::from("/work/src")]);
        let watched = ["/work", "/work/src", "/work/src/nested", "/work/src-other"]
            .into_iter()
            .map(PathBuf::from)
            .collect();
        add_policy_watches(&mut dirs, &HashSet::new(), &watched);
        assert_eq!(sorted_paths(dirs.clone()), ["/work/src"]);
        add_policy_watches(
            &mut dirs,
            &HashSet::from([PathBuf::from("/work/src")]),
            &watched,
        );
        assert_eq!(sorted_paths(dirs), ["/work/src", "/work/src/nested"]);
    }

    #[test]
    fn event_paths_resolve_to_the_watched_directory() {
        let mut watched = HashSet::new();
        watched.insert(PathBuf::from("/repo/src"));

        assert_eq!(
            owning_watched_dir(&watched, Path::new("/repo/src")),
            Some(PathBuf::from("/repo/src"))
        );
        assert_eq!(
            owning_watched_dir(&watched, Path::new("/repo/src/main.rs")),
            Some(PathBuf::from("/repo/src"))
        );
        assert_eq!(
            owning_watched_dir(&watched, Path::new("/repo/other/x")),
            None
        );
        assert_eq!(owning_watched_dir(&watched, Path::new("/elsewhere")), None);
    }
}
