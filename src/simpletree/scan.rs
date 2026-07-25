use crate::protocol::{Entry, Event, normalize_page};
use crate::server::{EventTx, send_event_unless_cancelled};
use anyhow::{Context, Result, bail};
use ignore::WalkBuilder;
use std::cmp::Ordering;
use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::UNIX_EPOCH;
use tokio_util::sync::CancellationToken;

#[derive(Debug, Default, Clone)]
pub struct ScanResult {
    pub entries: Vec<Entry>,
    pub warnings: Vec<String>,
}

const MAX_CACHED_DIRS: usize = 256;

pub type CacheKey = (PathBuf, bool, bool, bool);

pub fn cache_key(path: &Path, options: ScanOptions) -> CacheKey {
    (
        path.to_path_buf(),
        options.show_hidden,
        options.git_ignore,
        options.meta,
    )
}

#[derive(Default)]
struct CacheInner {
    map: HashMap<CacheKey, Arc<ScanResult>>,
    epoch: u64,
}

/// Sorted listing cache for directories that are currently watched — only a
/// watch provides the invalidation signal that makes reuse safe. The epoch
/// guards against a scan finishing after its directory was invalidated.
#[derive(Clone, Default)]
pub struct ScanCache {
    inner: Arc<Mutex<CacheInner>>,
}

impl ScanCache {
    pub fn get(&self, key: &CacheKey) -> Option<Arc<ScanResult>> {
        self.inner.lock().ok()?.map.get(key).cloned()
    }

    pub fn epoch(&self) -> u64 {
        self.inner.lock().map(|inner| inner.epoch).unwrap_or(0)
    }

    /// Store a result unless any invalidation happened since `epoch` was read.
    pub fn store_if_epoch(&self, key: CacheKey, result: Arc<ScanResult>, epoch: u64) {
        let Ok(mut inner) = self.inner.lock() else {
            return;
        };
        if inner.epoch != epoch {
            return;
        }
        if inner.map.len() >= MAX_CACHED_DIRS {
            // Simple pressure valve; refills quickly from watched dirs.
            inner.map.clear();
        }
        inner.map.insert(key, result);
    }

    pub fn evict_dir(&self, dir: &Path) {
        if let Ok(mut inner) = self.inner.lock() {
            inner.epoch = inner.epoch.wrapping_add(1);
            inner.map.retain(|key, _| key.0 != dir);
        }
    }

    pub fn clear(&self) {
        if let Ok(mut inner) = self.inner.lock() {
            inner.epoch = inner.epoch.wrapping_add(1);
            inner.map.clear();
        }
    }
}

#[derive(Debug, Clone, Copy)]
pub struct ScanOptions {
    pub show_hidden: bool,
    pub git_ignore: bool,
    pub meta: bool,
}

pub fn scan_directory(
    path: &Path,
    options: ScanOptions,
    cancel: &CancellationToken,
) -> Result<ScanResult> {
    let metadata = fs::metadata(path)
        .with_context(|| format!("failed to inspect directory: {}", path.display()))?;
    if !metadata.is_dir() {
        bail!("not a directory: {}", path.display());
    }
    fs::read_dir(path).with_context(|| format!("failed to read directory: {}", path.display()))?;

    let mut builder = WalkBuilder::new(path);
    builder
        .follow_links(false)
        .hidden(!options.show_hidden)
        .git_ignore(options.git_ignore)
        .git_global(options.git_ignore)
        .git_exclude(options.git_ignore)
        .parents(options.git_ignore)
        .max_depth(Some(1));

    let mut result = ScanResult::default();
    for dent in builder.build() {
        if cancel.is_cancelled() {
            return Ok(ScanResult::default());
        }

        // One unreadable child must not fail the whole listing; report and move on.
        let dent = match dent {
            Ok(dent) => dent,
            Err(error) => {
                result
                    .warnings
                    .push(format!("skipped unreadable entry: {error}"));
                continue;
            }
        };
        if dent.depth() == 0 {
            continue;
        }

        let entry_path = dent.path().to_path_buf();
        let Some(raw_name) = entry_path.file_name() else {
            continue;
        };
        let name = raw_name.to_string_lossy();
        let non_utf8 = raw_name.to_str().is_none();
        if non_utf8 {
            result
                .warnings
                .push(format!("entry name is not valid UTF-8: {}", name));
        }

        let file_type = dent.file_type();
        let is_symlink = file_type.is_some_and(|kind| kind.is_symlink());
        let is_dir = match file_type {
            Some(kind) if kind.is_dir() => true,
            Some(kind) if kind.is_symlink() => {
                fs::metadata(&entry_path).is_ok_and(|metadata| metadata.is_dir())
            }
            Some(_) => false,
            None => fs::metadata(&entry_path).is_ok_and(|metadata| metadata.is_dir()),
        };

        let mut entry = Entry::new(
            name.into_owned(),
            entry_path.to_string_lossy().into_owned(),
            is_dir,
        );
        entry.is_symlink = is_symlink;
        entry.non_utf8 = non_utf8;
        if options.meta {
            // lstat the entry itself; a broken symlink still gets its own metadata.
            if let Ok(metadata) = fs::symlink_metadata(&entry_path) {
                if metadata.is_file() {
                    entry.size = Some(metadata.len());
                }
                entry.mtime = metadata
                    .modified()
                    .ok()
                    .and_then(|time| time.duration_since(UNIX_EPOCH).ok())
                    .map(|elapsed| elapsed.as_secs() as i64);
            }
        }
        result.entries.push(entry);
    }

    result.entries = sort_entries(result.entries);
    Ok(result)
}

pub fn sort_entries(entries: Vec<Entry>) -> Vec<Entry> {
    let mut keyed: Vec<(String, Entry)> = entries
        .into_iter()
        .map(|entry| (entry.name.to_lowercase(), entry))
        .collect();

    keyed.sort_unstable_by(compare_keyed_entries);
    keyed.into_iter().map(|(_, entry)| entry).collect()
}

fn compare_keyed_entries(left: &(String, Entry), right: &(String, Entry)) -> Ordering {
    right
        .1
        .is_dir
        .cmp(&left.1.is_dir)
        .then_with(|| left.0.cmp(&right.0))
        .then_with(|| left.1.name.cmp(&right.1.name))
        .then_with(|| left.1.path.cmp(&right.1.path))
}

pub async fn emit_entries(
    id: u64,
    result: ScanResult,
    page: usize,
    out: &EventTx,
    cancel: &CancellationToken,
) -> Result<()> {
    let page = normalize_page(page);
    let ScanResult { entries, warnings } = result;
    if entries.is_empty() {
        let event = Event::ListChunk {
            id,
            entries: Vec::new(),
            done: true,
            warnings,
        };
        send_event_unless_cancelled(out, &event, cancel).await?;
        return Ok(());
    }

    let mut entries = entries.into_iter();
    let mut warnings = Some(warnings);
    while !entries.as_slice().is_empty() {
        let remaining = entries.len();
        let chunk: Vec<Entry> = entries.by_ref().take(page).collect();
        let done = chunk.len() == remaining;
        let event = Event::ListChunk {
            id,
            done,
            entries: chunk,
            // Warnings ride on the final chunk so consumers see them once.
            warnings: if done {
                warnings.take().unwrap_or_default()
            } else {
                Vec::new()
            },
        };
        if !send_event_unless_cancelled(out, &event, cancel).await? {
            break;
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entry(name: &str, is_dir: bool) -> Entry {
        Entry::new(name.to_owned(), format!("/tmp/{name}"), is_dir)
    }

    #[test]
    fn cache_serves_stored_results_and_eviction_is_scoped() {
        let cache = ScanCache::default();
        let key_a = (PathBuf::from("/a"), false, true, false);
        let key_b = (PathBuf::from("/b"), false, true, false);
        let epoch = cache.epoch();
        cache.store_if_epoch(key_a.clone(), Arc::new(ScanResult::default()), epoch);
        cache.store_if_epoch(key_b.clone(), Arc::new(ScanResult::default()), epoch);
        assert!(cache.get(&key_a).is_some());

        cache.evict_dir(Path::new("/a"));
        assert!(cache.get(&key_a).is_none());
        assert!(cache.get(&key_b).is_some());

        cache.clear();
        assert!(cache.get(&key_b).is_none());
    }

    #[test]
    fn stale_scans_do_not_repopulate_the_cache() {
        let cache = ScanCache::default();
        let key = (PathBuf::from("/a"), false, true, false);
        let epoch = cache.epoch();
        cache.evict_dir(Path::new("/a"));
        cache.store_if_epoch(key.clone(), Arc::new(ScanResult::default()), epoch);
        assert!(cache.get(&key).is_none());
    }

    #[test]
    fn sorting_is_directory_first_case_insensitive_and_deterministic() {
        let entries = vec![
            entry("b", false),
            entry("a", false),
            entry("A", false),
            entry("z", true),
            entry("Z", true),
        ];
        let entries = sort_entries(entries);

        let names: Vec<_> = entries.iter().map(|entry| entry.name.as_str()).collect();
        assert_eq!(names, ["Z", "z", "A", "a", "b"]);
    }
}
