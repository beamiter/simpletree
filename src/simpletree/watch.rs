use crate::git::GitCache;
use crate::protocol::Event;
use crate::scan::ScanCache;
use crate::server::{EventTx, send_event};
use anyhow::{Context, Result, bail};
use notify::{RecommendedWatcher, RecursiveMode, Watcher};
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
    /// Ignore-rule files influence listings far beyond their own directory,
    /// so their changes clear the whole scan cache instead of one entry.
    ignore_rules_changed: bool,
}

fn is_ignore_rules_file(path: &Path) -> bool {
    matches!(
        path.file_name().and_then(|name| name.to_str()),
        Some(".gitignore" | ".ignore" | "exclude")
    )
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
            let Ok(watched) = handler_watched.lock() else {
                return;
            };
            for path in &event.paths {
                if let Some(dir) = owning_watched_dir(&watched, path) {
                    // Send failures mean the daemon is shutting down.
                    let _ = raw_tx.send(RawChange {
                        dir,
                        ignore_rules_changed: is_ignore_rules_file(path),
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
) {
    while let Some(first) = rx.recv().await {
        let mut dirs: HashSet<PathBuf> = HashSet::new();
        let mut ignore_rules_changed = first.ignore_rules_changed;
        dirs.insert(first.dir);
        let deadline = Instant::now() + HARD_DEADLINE;

        loop {
            tokio::select! {
                _ = sleep(QUIET_WINDOW) => break,
                _ = sleep_until(deadline) => break,
                more = rx.recv() => match more {
                    Some(change) => {
                        ignore_rules_changed |= change.ignore_rules_changed;
                        dirs.insert(change.dir);
                    }
                    None => break,
                }
            }
        }

        if ignore_rules_changed {
            scan_cache.clear();
        } else {
            for dir in &dirs {
                scan_cache.evict_dir(dir);
            }
        }
        // Any filesystem change may move git state; refresh on next query.
        git_cache.mark_all_dirty();

        let mut dirs: Vec<String> = dirs
            .into_iter()
            .map(|dir| dir.to_string_lossy().into_owned())
            .collect();
        dirs.sort_unstable();
        if send_event(&out, &Event::FsEvent { dirs }).await.is_err() {
            return;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

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
