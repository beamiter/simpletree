mod fsops;
mod git;
mod protocol;
mod scan;
mod search;
mod server;
mod watch;

use anyhow::{Context, Result, bail};
use protocol::{
    BASE_CAPABILITIES, Event, OUTPUT_CHANNEL_CAPACITY, PROTOCOL_VERSION, Request,
    best_effort_request_id, normalize_page,
};
use scan::{ScanOptions, emit_entries, scan_directory};
use server::{
    ActiveRequests, EventTx, activate_request, remove_active_if_generation, send_event,
    send_event_unless_cancelled, stdout_writer,
};
use std::{collections::HashMap, path::PathBuf, sync::Arc, time::Instant};
use tokio::{
    io::{AsyncBufReadExt, BufReader},
    sync::{Mutex, Semaphore, mpsc},
    task::{JoinError, JoinSet},
};
use tokio_util::sync::CancellationToken;

macro_rules! debug_log {
    ($($arg:tt)*) => {
        if cfg!(debug_assertions) {
            eprintln!($($arg)*);
        }
    };
}

fn runtime_capabilities(watch_available: bool, git_available: bool) -> Vec<&'static str> {
    let mut capabilities = BASE_CAPABILITIES.to_vec();
    capabilities.push("search");
    capabilities.push("fs-ops");
    if watch_available {
        capabilities.push("watch");
    }
    if git_available {
        capabilities.push("git-status");
    }
    capabilities
}

/// Scans a real directory in-process and checks the handshake reply.
///
/// The installer needs to know that the binary it just built actually works,
/// and a version string only proves the file is not corrupt.  A scan exercises
/// the directory walk — the one code path every session starts with, and the
/// one that depends on the `ignore` crate being linked and functional.
fn self_test() -> Result<()> {
    let directory = std::env::temp_dir();
    let cancel = CancellationToken::new();
    let options = ScanOptions {
        show_hidden: false,
        git_ignore: true,
        meta: true,
    };
    scan_directory(&directory, options, &cancel)
        .with_context(|| format!("scanning {} failed", directory.display()))?;

    let capabilities = runtime_capabilities(true, true);
    if !capabilities.contains(&"search") {
        bail!("handshake omitted the search capability");
    }
    if PROTOCOL_VERSION == 0 {
        bail!("handshake announces protocol 0");
    }
    Ok(())
}

fn handle_cli() -> Result<bool> {
    let mut args = std::env::args().skip(1);
    let Some(arg) = args.next() else {
        return Ok(false);
    };
    if args.next().is_some() {
        bail!("too many command-line arguments");
    }

    match arg.as_str() {
        "--version" | "-V" => {
            println!("simpletree-daemon {}", env!("CARGO_PKG_VERSION"));
            Ok(true)
        }
        "--help" | "-h" => {
            println!(
                "simpletree-daemon {}\n\nUSAGE:\n    simpletree-daemon\n    simpletree-daemon --version\n    simpletree-daemon --self-test\n\nThe default mode reads one JSON request per line from stdin and writes one JSON event per line to stdout.\n--self-test scans a directory in-process and checks the handshake reply, then exits.",
                env!("CARGO_PKG_VERSION")
            );
            Ok(true)
        }
        "--self-test" => {
            self_test()?;
            println!("ok");
            Ok(true)
        }
        _ => bail!("unknown command-line argument: {arg}"),
    }
}

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<()> {
    if handle_cli()? {
        return Ok(());
    }

    let stdin = BufReader::new(tokio::io::stdin());
    let mut lines = stdin.lines();
    debug_log!("start");

    // A bounded queue provides backpressure when Vim is slow. The writer drains
    // bursts before flushing so large directories do not pay one flush per page.
    let (out_tx, out_rx) = mpsc::channel::<String>(OUTPUT_CHANNEL_CAPACITY);
    let writer = tokio::spawn(stdout_writer(out_rx));

    let active: ActiveRequests = Arc::new(Mutex::new(HashMap::new()));
    let scan_slots = Arc::new(Semaphore::new(protocol::MAX_CONCURRENT_SCANS));
    let mut tasks: JoinSet<Result<()>> = JoinSet::new();
    let mut next_generation = 0_u64;
    let git_cache = git::GitCache::default();
    let git_available = git::git_available();
    let scan_cache = scan::ScanCache::default();
    let mut watch_service =
        watch::WatchService::start(out_tx.clone(), git_cache.clone(), scan_cache.clone());

    loop {
        tokio::select! {
            completed = tasks.join_next(), if !tasks.is_empty() => {
                if let Some(completed) = completed {
                    finish_request_task(completed);
                }
            }
            line = lines.next_line() => {
                let Some(line) = line? else {
                    break;
                };
                if line.trim().is_empty() {
                    continue;
                }

                debug_log!("REQ LINE: {line}");
                let req = match serde_json::from_str::<Request>(&line) {
                    Ok(request) => request,
                    Err(error) => {
                        debug_log!("REQ PARSE ERR: {error}");
                        send_event(
                            &out_tx,
                            &Event::Error {
                                id: best_effort_request_id(&line),
                                message: format!("invalid request: {error}"),
                            },
                        )
                        .await?;
                        continue;
                    }
                };
                debug_log!("REQ DECODED: {req:?}");

                match req {
                    Request::Ping { id } => {
                        send_event(
                            &out_tx,
                            &Event::Pong {
                                id,
                                protocol_version: PROTOCOL_VERSION,
                                daemon_version: env!("CARGO_PKG_VERSION"),
                                capabilities: runtime_capabilities(
                                    watch_service.is_some(),
                                    git_available,
                                ),
                            },
                        )
                        .await?;
                    }
                    Request::List {
                        id,
                        path,
                        show_hidden,
                        git_ignore,
                        max,
                        meta,
                    } => {
                        let Some((generation, cancel)) =
                            begin_request(&active, &mut next_generation, id, &out_tx).await?
                        else {
                            continue;
                        };

                        let path = PathBuf::from(path);
                        let options = ScanOptions { show_hidden, git_ignore, meta };
                        // Cached listings are only trusted while the directory
                        // is watched; only a watch delivers invalidation.
                        let cacheable = watch_service
                            .as_ref()
                            .is_some_and(|service| service.is_watched(&path));
                        tasks.spawn(run_list_request(
                            id,
                            generation,
                            path,
                            options,
                            normalize_page(max),
                            out_tx.clone(),
                            cancel,
                            active.clone(),
                            scan_slots.clone(),
                            cacheable.then(|| scan_cache.clone()),
                        ));
                    }
                    Request::GitStatus { id, path, force } => {
                        let Some((generation, cancel)) =
                            begin_request(&active, &mut next_generation, id, &out_tx).await?
                        else {
                            continue;
                        };

                        tasks.spawn(run_git_status_request(
                            id,
                            generation,
                            PathBuf::from(path),
                            force,
                            git_cache.clone(),
                            out_tx.clone(),
                            cancel,
                            active.clone(),
                        ));
                    }
                    Request::Search {
                        id,
                        root,
                        query,
                        mode,
                        max_results,
                        show_hidden,
                        git_ignore,
                    } => {
                        let Some((generation, cancel)) =
                            begin_request(&active, &mut next_generation, id, &out_tx).await?
                        else {
                            continue;
                        };

                        let options = search::SearchOptions {
                            mode,
                            max_results: search::normalize_max_results(max_results),
                            show_hidden,
                            git_ignore,
                        };
                        tasks.spawn(run_search_request(
                            id,
                            generation,
                            PathBuf::from(root),
                            query,
                            options,
                            out_tx.clone(),
                            cancel,
                            active.clone(),
                            scan_slots.clone(),
                        ));
                    }
                    Request::FsOp { id, op, src, dst } => {
                        let Some((generation, cancel)) =
                            begin_request(&active, &mut next_generation, id, &out_tx).await?
                        else {
                            continue;
                        };

                        tasks.spawn(run_fs_op_request(
                            id,
                            generation,
                            op,
                            PathBuf::from(src),
                            PathBuf::from(dst),
                            out_tx.clone(),
                            cancel,
                            active.clone(),
                            scan_slots.clone(),
                        ));
                    }
                    Request::Cancel { id } => {
                        let cancel = {
                            let requests = active.lock().await;
                            requests.get(&id).map(|request| request.cancel.clone())
                        };
                        if let Some(cancel) = cancel {
                            cancel.cancel();
                        }
                    }
                    Request::Watch { id, path } => {
                        let event = match watch_service.as_mut() {
                            None => Event::Error {
                                id,
                                message: "filesystem watching is unavailable".to_owned(),
                            },
                            Some(service) => match service.watch(std::path::Path::new(&path)) {
                                Ok(()) => Event::Ok { id },
                                Err(error) => Event::Error {
                                    id,
                                    message: error.to_string(),
                                },
                            },
                        };
                        send_event(&out_tx, &event).await?;
                    }
                    Request::Unwatch { id, path } => {
                        if let Some(service) = watch_service.as_mut() {
                            service.unwatch(std::path::Path::new(&path));
                        }
                        send_event(&out_tx, &Event::Ok { id }).await?;
                    }
                }
            }
        }
    }

    // EOF means no more requests, but accepted work and queued protocol records
    // must finish before the process exits.
    while let Some(completed) = tasks.join_next().await {
        finish_request_task(completed);
    }
    // The watcher owns the raw-event sender and its debounce task holds an
    // EventTx clone; dropping the service closes that chain so the writer can
    // observe channel shutdown. Without this the daemon never exits on EOF.
    drop(watch_service);
    drop(out_tx);
    writer.await.context("stdout writer task failed")??;
    Ok(())
}

/// A failed or panicked request task must not take the daemon down; per-request
/// errors were already delivered as protocol events where possible.
fn finish_request_task(completed: std::result::Result<Result<()>, JoinError>) {
    match completed {
        Ok(Ok(())) => {}
        Ok(Err(error)) => debug_log!("request task error: {error}"),
        Err(join_error) => eprintln!("request task panicked or was aborted: {join_error}"),
    }
}

/// Allocate a generation and register the request id. Returns Ok(None) after
/// reporting the active-request limit to the client.
async fn begin_request(
    active: &ActiveRequests,
    next_generation: &mut u64,
    id: u64,
    out: &EventTx,
) -> Result<Option<(u64, CancellationToken)>> {
    *next_generation = next_generation.wrapping_add(1);
    if *next_generation == 0 {
        *next_generation = 1;
    }
    let generation = *next_generation;
    let cancel = CancellationToken::new();
    let accepted = {
        let mut requests = active.lock().await;
        activate_request(&mut requests, id, generation, cancel.clone())
    };

    if !accepted {
        send_event(
            out,
            &Event::Error {
                id,
                message: format!(
                    "too many active requests (limit {})",
                    protocol::MAX_ACTIVE_REQUESTS
                ),
            },
        )
        .await?;
        return Ok(None);
    }
    Ok(Some((generation, cancel)))
}

/// Convert a request outcome into protocol delivery (errors become error
/// events, cancellation is silent) and release the request slot.
async fn end_request(
    id: u64,
    generation: u64,
    result: Result<()>,
    out: &EventTx,
    cancel: &CancellationToken,
    active: &ActiveRequests,
) -> Result<()> {
    let delivery = match result {
        Ok(()) => Ok(()),
        Err(_) if cancel.is_cancelled() => Ok(()),
        Err(error) => {
            let event = Event::Error {
                id,
                message: error.to_string(),
            };
            send_event_unless_cancelled(out, &event, cancel)
                .await
                .map(|_| ())
        }
    };

    {
        let mut requests = active.lock().await;
        remove_active_if_generation(&mut requests, id, generation);
    }
    delivery
}

#[allow(clippy::too_many_arguments)]
async fn run_list_request(
    id: u64,
    generation: u64,
    path: PathBuf,
    options: ScanOptions,
    page: usize,
    out: EventTx,
    cancel: CancellationToken,
    active: ActiveRequests,
    scan_slots: Arc<Semaphore>,
    cache: Option<scan::ScanCache>,
) -> Result<()> {
    let result = handle_list(
        id,
        path,
        options,
        page,
        out.clone(),
        cancel.clone(),
        scan_slots,
        cache,
    )
    .await;
    end_request(id, generation, result, &out, &cancel, &active).await
}

#[allow(clippy::too_many_arguments)]
async fn run_git_status_request(
    id: u64,
    generation: u64,
    path: PathBuf,
    force: bool,
    cache: git::GitCache,
    out: EventTx,
    cancel: CancellationToken,
    active: ActiveRequests,
) -> Result<()> {
    let result = handle_git_status(id, path, force, cache, out.clone(), cancel.clone()).await;
    end_request(id, generation, result, &out, &cancel, &active).await
}

async fn handle_git_status(
    id: u64,
    path: PathBuf,
    force: bool,
    cache: git::GitCache,
    out: EventTx,
    cancel: CancellationToken,
) -> Result<()> {
    let status = tokio::select! {
        biased;
        _ = cancel.cancelled() => return Ok(()),
        status = git::repo_status(&cache, &path, force) => status?,
    };

    let event = Event::GitStatus {
        id,
        repo_root: status.repo_root.to_string_lossy().into_owned(),
        statuses: status.statuses.as_ref().clone(),
        done: true,
        truncated: status.truncated,
    };
    send_event_unless_cancelled(&out, &event, &cancel).await?;
    Ok(())
}

#[allow(clippy::too_many_arguments)]
async fn run_fs_op_request(
    id: u64,
    generation: u64,
    op: fsops::FsOpKind,
    src: PathBuf,
    dst: PathBuf,
    out: EventTx,
    cancel: CancellationToken,
    active: ActiveRequests,
    scan_slots: Arc<Semaphore>,
) -> Result<()> {
    let result = handle_fs_op(id, op, src, dst, out.clone(), cancel.clone(), scan_slots).await;
    end_request(id, generation, result, &out, &cancel, &active).await
}

/// A copy can move gigabytes, so it takes a scan permit: the eight-slot
/// semaphore is what keeps a paste from starving the directory listings the
/// tree needs to stay responsive while the paste runs.
async fn handle_fs_op(
    id: u64,
    op: fsops::FsOpKind,
    src: PathBuf,
    dst: PathBuf,
    out: EventTx,
    cancel: CancellationToken,
    scan_slots: Arc<Semaphore>,
) -> Result<()> {
    let _permit = tokio::select! {
        biased;
        _ = cancel.cancelled() => return Ok(()),
        permit = scan_slots.acquire_owned() => permit.context("directory scan limiter closed")?,
    };

    let started = Instant::now();
    let op_cancel = cancel.clone();
    let outcome = tokio::task::spawn_blocking(move || fsops::run(op, &src, &dst, &op_cancel))
        .await
        .context("filesystem operation task failed")?;
    debug_log!(
        "handle_fs_op done id={id} installed={} elapsed_ms={}",
        outcome.installed,
        started.elapsed().as_millis()
    );

    send_event_unless_cancelled(&out, &Event::FsOpDone { id, outcome }, &cancel).await?;
    Ok(())
}

#[allow(clippy::too_many_arguments)]
async fn run_search_request(
    id: u64,
    generation: u64,
    root: PathBuf,
    query: String,
    options: search::SearchOptions,
    out: EventTx,
    cancel: CancellationToken,
    active: ActiveRequests,
    scan_slots: Arc<Semaphore>,
) -> Result<()> {
    let result = async {
        let _permit = tokio::select! {
            biased;
            _ = cancel.cancelled() => return Ok(()),
            permit = scan_slots.acquire_owned() => permit.context("directory scan limiter closed")?,
        };
        search::handle_search(id, root, query, options, out.clone(), cancel.clone()).await
    }
    .await;
    end_request(id, generation, result, &out, &cancel, &active).await
}

#[allow(clippy::too_many_arguments)]
async fn handle_list(
    id: u64,
    path: PathBuf,
    options: ScanOptions,
    page: usize,
    out: EventTx,
    cancel: CancellationToken,
    scan_slots: Arc<Semaphore>,
    cache: Option<scan::ScanCache>,
) -> Result<()> {
    let key = scan::cache_key(&path, options);
    if let Some(hit) = cache.as_ref().and_then(|cache| cache.get(&key)) {
        debug_log!("handle_list cache hit id={id} path={path:?}");
        return emit_entries(id, hit.as_ref().clone(), page, &out, &cancel).await;
    }

    let _permit = tokio::select! {
        biased;
        _ = cancel.cancelled() => return Ok(()),
        permit = scan_slots.acquire_owned() => permit.context("directory scan limiter closed")?,
    };

    debug_log!("handle_list start id={id} path={path:?}");
    let started = Instant::now();
    let epoch = cache.as_ref().map(scan::ScanCache::epoch);
    let scan_cancel = cancel.clone();
    let result = tokio::task::spawn_blocking(move || scan_directory(&path, options, &scan_cancel))
        .await
        .context("directory scanner task failed")??;

    debug_log!(
        "handle_list done id={id} entries={} elapsed_ms={}",
        result.entries.len(),
        started.elapsed().as_millis()
    );
    if cancel.is_cancelled() {
        return Ok(());
    }

    if let (Some(cache), Some(epoch)) = (cache.as_ref(), epoch) {
        cache.store_if_epoch(key, Arc::new(result.clone()), epoch);
    }
    emit_entries(id, result, page, &out, &cancel).await
}
