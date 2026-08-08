use crate::protocol::{Entry, Event};
use crate::server::{EventTx, send_event_unless_cancelled};
use anyhow::{Context, Result, bail};
use ignore::WalkBuilder;
use serde::Deserialize;
use std::fs;
use std::path::Path;
use tokio::sync::mpsc;
use tokio_util::sync::CancellationToken;

pub const MAX_SEARCH_RESULTS: usize = 2_000;
const DEFAULT_SEARCH_RESULTS: usize = 200;
const MAX_SEARCH_DEPTH: usize = 32;
const BATCH_SIZE: usize = 64;

#[derive(Debug, Clone, Copy, Default, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum SearchMode {
    #[default]
    Substring,
    Fuzzy,
}

#[derive(Debug, Clone, Copy)]
pub struct SearchOptions {
    pub mode: SearchMode,
    pub max_results: usize,
    pub show_hidden: bool,
    pub git_ignore: bool,
}

pub fn normalize_max_results(requested: Option<usize>) -> usize {
    requested
        .unwrap_or(DEFAULT_SEARCH_RESULTS)
        .clamp(1, MAX_SEARCH_RESULTS)
}

/// Case-insensitive filename match. Fuzzy means the query characters appear in
/// order; results stream in walk order and are not globally ranked.
pub fn name_matches(name: &str, query_lower: &str, mode: SearchMode) -> bool {
    if query_lower.is_empty() {
        return false;
    }
    let name_lower = name.to_lowercase();
    match mode {
        SearchMode::Substring => name_lower.contains(query_lower),
        SearchMode::Fuzzy => {
            let mut pending = query_lower.chars().peekable();
            for ch in name_lower.chars() {
                if pending.peek() == Some(&ch) {
                    pending.next();
                }
            }
            pending.peek().is_none()
        }
    }
}

/// Blocking recursive walk; matches flow through the batch channel so results
/// stream while the walk continues.
fn search_worker(
    root: &Path,
    query: &str,
    options: SearchOptions,
    cancel: &CancellationToken,
    batches: mpsc::Sender<Vec<Entry>>,
) -> Result<()> {
    let metadata = fs::metadata(root)
        .with_context(|| format!("failed to inspect directory: {}", root.display()))?;
    if !metadata.is_dir() {
        bail!("not a directory: {}", root.display());
    }

    let query_lower = query.to_lowercase();
    let mut builder = WalkBuilder::new(root);
    builder
        .follow_links(false)
        .hidden(!options.show_hidden)
        .git_ignore(options.git_ignore)
        .git_global(options.git_ignore)
        .git_exclude(options.git_ignore)
        .parents(options.git_ignore)
        .max_depth(Some(MAX_SEARCH_DEPTH));

    let mut batch: Vec<Entry> = Vec::new();
    let mut found = 0_usize;
    for dent in builder.build() {
        if cancel.is_cancelled() {
            return Ok(());
        }
        let Ok(dent) = dent else {
            continue;
        };
        if dent.depth() == 0 {
            continue;
        }
        let Some(raw_name) = dent.path().file_name() else {
            continue;
        };
        let name = raw_name.to_string_lossy();
        if !name_matches(&name, &query_lower, options.mode) {
            continue;
        }

        let is_dir = dent.file_type().is_some_and(|kind| kind.is_dir());
        let mut entry = Entry::new(
            name.into_owned(),
            dent.path().to_string_lossy().into_owned(),
            is_dir,
        );
        entry.is_symlink = dent.file_type().is_some_and(|kind| kind.is_symlink());
        entry.non_utf8 = raw_name.to_str().is_none();
        batch.push(entry);
        found += 1;

        if batch.len() >= BATCH_SIZE && batches.blocking_send(std::mem::take(&mut batch)).is_err() {
            return Ok(());
        }
        if found >= options.max_results {
            break;
        }
    }

    if !batch.is_empty() {
        let _ = batches.blocking_send(batch);
    }
    Ok(())
}

pub async fn handle_search(
    id: u64,
    root: std::path::PathBuf,
    query: String,
    options: SearchOptions,
    out: EventTx,
    cancel: CancellationToken,
) -> Result<()> {
    let (batch_tx, mut batch_rx) = mpsc::channel::<Vec<Entry>>(4);
    let worker_cancel = cancel.clone();
    let worker = tokio::task::spawn_blocking(move || {
        search_worker(&root, &query, options, &worker_cancel, batch_tx)
    });

    while let Some(entries) = batch_rx.recv().await {
        let event = Event::SearchChunk {
            id,
            entries,
            done: false,
        };
        if !send_event_unless_cancelled(&out, &event, &cancel).await? {
            break;
        }
    }

    // Drop the receiver before awaiting: on the cancelled path the walk is
    // usually parked in `blocking_send()` on this bounded channel, and
    // `blocking_send` only fails once the receiver is gone.  Awaiting while
    // still holding `batch_rx` hung here forever, and the caller's owned scan
    // permit went with it — eight cancelled searches and no directory in the
    // session could be listed again.
    drop(batch_rx);
    worker.await.context("search worker task failed")??;
    if cancel.is_cancelled() {
        return Ok(());
    }
    let done = Event::SearchChunk {
        id,
        entries: Vec::new(),
        done: true,
    };
    send_event_unless_cancelled(&out, &done, &cancel).await?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn substring_matching_is_case_insensitive() {
        assert!(name_matches("Main.RS", "main", SearchMode::Substring));
        assert!(name_matches("main.rs", "ain.r", SearchMode::Substring));
        assert!(!name_matches("main.rs", "xyz", SearchMode::Substring));
        assert!(!name_matches("main.rs", "", SearchMode::Substring));
    }

    #[test]
    fn fuzzy_matching_requires_ordered_subsequence() {
        assert!(name_matches(
            "simpletree_daemon.rs",
            "stdrs",
            SearchMode::Fuzzy
        ));
        assert!(name_matches("Makefile", "mkf", SearchMode::Fuzzy));
        assert!(!name_matches("Makefile", "fkm", SearchMode::Fuzzy));
        assert!(!name_matches("abc", "", SearchMode::Fuzzy));
    }

    #[test]
    fn search_result_limits_are_clamped() {
        assert_eq!(normalize_max_results(None), DEFAULT_SEARCH_RESULTS);
        assert_eq!(normalize_max_results(Some(0)), 1);
        assert_eq!(normalize_max_results(Some(usize::MAX)), MAX_SEARCH_RESULTS);
    }

    /// A cancelled search used to deadlock and leak one of the eight
    /// concurrent-scan permits: the consumer broke out of the batch loop and
    /// awaited the worker while still holding the receiver, and the worker was
    /// parked in `blocking_send()` on a bounded channel that only errors once
    /// the receiver is *dropped*.  After eight cancellations every directory
    /// listing in the session stopped.
    ///
    /// The setup reproduces the parked worker deterministically: the event
    /// channel holds one message and is never drained, so the consumer stalls
    /// after a single chunk while the walk keeps producing.
    #[test]
    fn cancelling_a_search_releases_its_blocking_worker() {
        let directory = tempfile::tempdir().expect("temporary directory");
        for index in 0..(BATCH_SIZE * 8) {
            std::fs::write(directory.path().join(format!("match_{index}.rs")), b"x")
                .expect("fixture");
        }

        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .expect("runtime");

        runtime.block_on(async {
            let (out, _undrained) = mpsc::channel::<String>(1);
            let cancel = CancellationToken::new();
            let task = tokio::spawn(handle_search(
                7,
                directory.path().to_path_buf(),
                "match".to_string(),
                SearchOptions {
                    mode: SearchMode::Substring,
                    max_results: MAX_SEARCH_RESULTS,
                    show_hidden: false,
                    git_ignore: false,
                },
                out,
                cancel.clone(),
            ));

            // Long enough for the walk to fill both channels and park.
            tokio::time::sleep(std::time::Duration::from_millis(300)).await;
            cancel.cancel();

            let joined = tokio::time::timeout(std::time::Duration::from_secs(10), task)
                .await
                .expect("cancelled search never returned; its blocking worker is still parked");
            joined
                .expect("search task panicked")
                .expect("cancelled search reported an error");
        });
    }
}
