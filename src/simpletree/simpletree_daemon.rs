mod fsops;
mod git;
mod protocol;
mod scan;
mod search;
mod server;
mod watch;

use anyhow::{Context, Result, bail};
use protocol::{
    BASE_CAPABILITIES, Event, MAX_REQUEST_LINE_BYTES, OUTPUT_CHANNEL_CAPACITY, PROTOCOL_VERSION,
    Request, best_effort_request_id, normalize_page,
};
use scan::{ScanOptions, emit_entries, scan_directory};
use server::{
    ActiveRequests, EventTx, RequestReader, activate_request, remove_active_if_generation,
    send_event, send_event_unless_cancelled, stdout_writer,
};
use std::{collections::HashMap, path::PathBuf, sync::Arc, time::Instant};
use tokio::{
    io::{AsyncRead, AsyncWrite, BufReader},
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
///
/// The handshake half used to re-derive the reply — it called
/// `runtime_capabilities(true, true)` itself and then asserted that `"search"`
/// was in the list `runtime_capabilities` pushes unconditionally, and that
/// `PROTOCOL_VERSION` (a `u32` constant of 2) was not `0`.  Neither line could
/// ever fail, in any build, for any edit.  It now does what simplegit's and
/// simpleline's self-tests do: drive the real request loop over a pipe and
/// parse the reply the daemon actually emitted, so a handshake that stops
/// announcing a capability, or announces the wrong protocol, is a failure.
async fn self_test() -> Result<()> {
    let directory = std::env::temp_dir();
    let cancel = CancellationToken::new();
    let options = ScanOptions {
        show_hidden: false,
        git_ignore: true,
        meta: true,
    };
    scan_directory(&directory, options, &cancel)
        .with_context(|| format!("scanning {} failed", directory.display()))?;

    let request = format!("{}\n", serde_json::json!({"type": "ping", "id": 1}));
    // `run` spawns its writer task, so the sink has to be owned and 'static —
    // a borrowed Vec will not do.  A duplex pipe gives an owned write half;
    // run drops it on the way out, which is what ends the read below.
    let (mut client, server) = tokio::io::duplex(64 * 1024);
    run(request.as_bytes(), server)
        .await
        .context("daemon loop failed")?;

    let mut reply = String::new();
    tokio::io::AsyncReadExt::read_to_string(&mut client, &mut reply)
        .await
        .context("could not read the handshake reply")?;
    let first = reply.lines().next().context("daemon produced no reply")?;
    let parsed: serde_json::Value =
        serde_json::from_str(first).context("handshake reply was not JSON")?;

    match parsed.get("protocol_version").and_then(|v| v.as_u64()) {
        Some(version) if version == u64::from(PROTOCOL_VERSION) => {}
        Some(version) => {
            bail!("daemon announced protocol {version}, this build is {PROTOCOL_VERSION}")
        }
        None => bail!("handshake reply carried no protocol version: {first}"),
    }

    let announced: Vec<&str> = parsed
        .get("capabilities")
        .and_then(|value| value.as_array())
        .map(|items| items.iter().filter_map(|item| item.as_str()).collect())
        .unwrap_or_default();
    for required in BASE_CAPABILITIES.iter().chain(["search", "fs-ops"].iter()) {
        if !announced.contains(required) {
            bail!("handshake omitted the {required} capability: {first}");
        }
    }
    Ok(())
}

async fn handle_cli() -> Result<bool> {
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
            self_test().await?;
            println!("ok");
            Ok(true)
        }
        _ => bail!("unknown command-line argument: {arg}"),
    }
}

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<()> {
    if handle_cli().await? {
        return Ok(());
    }
    run(tokio::io::stdin(), tokio::io::stdout()).await
}

/// The request loop, over any pipe.
///
/// It used to be the body of `main` and could only be reached through the real
/// stdin/stdout, which is why `--self-test` re-derived the handshake instead of
/// asking for one.  simplegit and simpleline both take the pipe as an argument
/// for exactly that reason.
async fn run<R, W>(input: R, output: W) -> Result<()>
where
    R: AsyncRead + Unpin,
    W: AsyncWrite + Unpin + Send + 'static,
{
    let mut lines = RequestReader::new(BufReader::new(input), MAX_REQUEST_LINE_BYTES);
    debug_log!("start");

    // A bounded queue provides backpressure when Vim is slow. The writer drains
    // bursts before flushing so large directories do not pay one flush per page.
    let (sender, out_rx) = mpsc::channel::<String>(OUTPUT_CHANNEL_CAPACITY);
    let out_tx = EventTx::new(sender);
    let writer = tokio::spawn(stdout_writer(out_rx, output));

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
        // Fail-closed: once the output path is declared dead there is nothing
        // left to answer with, so stop accepting work and drain.
        if out_tx.is_stalled() {
            break;
        }
        tokio::select! {
            completed = tasks.join_next(), if !tasks.is_empty() => {
                if let Some(completed) = completed {
                    finish_request_task(completed);
                }
            }
            // A producer that gave up on the stdout queue has to reach the loop
            // even while it is parked here on the stdin read; otherwise a
            // client that stopped reading wedges the daemon with no way out,
            // not even closing stdin.
            _ = out_tx.wait_stalled() => break,
            line = lines.next_line() => {
                let Some(line) = line? else {
                    break;
                };
                let line = match line {
                    Ok(line) => line,
                    Err(message) => {
                        debug_log!("REQ FRAMING ERR: {message}");
                        if send_event(&out_tx, &Event::Error { id: 0, message }).await.is_err() {
                            break;
                        }
                        continue;
                    }
                };
                if line.trim().is_empty() {
                    continue;
                }

                debug_log!("REQ LINE: {line}");
                let req = match serde_json::from_str::<Request>(&line) {
                    Ok(request) => request,
                    Err(error) => {
                        debug_log!("REQ PARSE ERR: {error}");
                        if send_event(
                            &out_tx,
                            &Event::Error {
                                id: best_effort_request_id(&line),
                                message: format!("invalid request: {error}"),
                            },
                        )
                        .await
                        .is_err()
                        {
                            break;
                        }
                        continue;
                    }
                };
                debug_log!("REQ DECODED: {req:?}");

                match req {
                    Request::Ping { id } => {
                        if send_event(
                            &out_tx,
                            &handshake_event(
                                id,
                                watch_service.is_some(),
                                git_available,
                            ),
                        )
                        .await
                        .is_err()
                        {
                            break;
                        }
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
                            begin_request(&active, &mut next_generation, id, &out_tx).await
                        else {
                            // Either the active-request limit refused it, or the
                            // refusal could not be delivered; the stall check at
                            // the top of the loop handles the second case.
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
                            begin_request(&active, &mut next_generation, id, &out_tx).await
                        else {
                            // Either the active-request limit refused it, or the
                            // refusal could not be delivered; the stall check at
                            // the top of the loop handles the second case.
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
                            scan_slots.clone(),
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
                            begin_request(&active, &mut next_generation, id, &out_tx).await
                        else {
                            // Either the active-request limit refused it, or the
                            // refusal could not be delivered; the stall check at
                            // the top of the loop handles the second case.
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
                            begin_request(&active, &mut next_generation, id, &out_tx).await
                        else {
                            // Either the active-request limit refused it, or the
                            // refusal could not be delivered; the stall check at
                            // the top of the loop handles the second case.
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
                        if send_event(&out_tx, &event).await.is_err() {
                            break;
                        }
                    }
                    Request::Unwatch { id, path } => {
                        if let Some(service) = watch_service.as_mut() {
                            service.unwatch(std::path::Path::new(&path));
                        }
                        if send_event(&out_tx, &Event::Ok { id }).await.is_err() {
                            break;
                        }
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

/// The handshake reply.
///
/// One function, so `--self-test` and the `ping` arm cannot disagree: the
/// self-test used to build its own capability list, which is why no edit to
/// the real handshake could ever make it fail.
fn handshake_event(id: u64, watch_available: bool, git_available: bool) -> Event {
    Event::Pong {
        id,
        protocol_version: PROTOCOL_VERSION,
        daemon_version: env!("CARGO_PKG_VERSION"),
        capabilities: runtime_capabilities(watch_available, git_available),
    }
}

/// Allocate a generation and register the request id. Returns None after
/// reporting the active-request limit to the client — or after failing to
/// report it, which only happens once the output path is already dead and the
/// loop's own stall check is about to end the loop.
async fn begin_request(
    active: &ActiveRequests,
    next_generation: &mut u64,
    id: u64,
    out: &EventTx,
) -> Option<(u64, CancellationToken)> {
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
        let _ = send_event(
            out,
            &Event::Error {
                id,
                message: format!(
                    "too many active requests (limit {})",
                    protocol::MAX_ACTIVE_REQUESTS
                ),
            },
        )
        .await;
        return None;
    }
    Some((generation, cancel))
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
    scan_slots: Arc<Semaphore>,
) -> Result<()> {
    let result = handle_git_status(
        id,
        path,
        force,
        cache,
        out.clone(),
        cancel.clone(),
        scan_slots,
    )
    .await;
    end_request(id, generation, result, &out, &cancel, &active).await
}

/// One request can cover several repositories: a tree rooted at a directory of
/// checkouts used to resolve to none at all and show no marks anywhere.  Each
/// repository gets its own event so the frontend can render the first one
/// without waiting for the last, and only the final event carries `done`.
#[allow(clippy::too_many_arguments)]
async fn handle_git_status(
    id: u64,
    path: PathBuf,
    force: bool,
    cache: git::GitCache,
    out: EventTx,
    cancel: CancellationToken,
    scan_slots: Arc<Semaphore>,
) -> Result<()> {
    // git status was the one handler that took no scan permit, so its only
    // bound was MAX_ACTIVE_REQUESTS: sixty-four concurrent `status -uall`
    // walks over the same worktree.  It walks a directory tree exactly like
    // list, search and fs_op do, so it queues behind the same eight slots.
    let _permit = tokio::select! {
        biased;
        _ = cancel.cancelled() => return Ok(()),
        permit = scan_slots.acquire_owned() => permit.context("directory scan limiter closed")?,
    };

    let discover_path = path.clone();
    let scopes = tokio::select! {
        biased;
        _ = cancel.cancelled() => return Ok(()),
        scopes = tokio::task::spawn_blocking(move || git::discover_repos(&discover_path)) =>
            scopes.context("repository discovery task failed")?,
    };
    if scopes.is_empty() {
        bail!("not inside a git repository: {}", path.display());
    }

    // The last successful repository carries `done`, so the one still in hand is
    // held back until the loop knows whether another will follow.  A repository
    // that fails inside a directory of them must not cost the others their
    // marks — but if every one of them fails, that is the answer.
    let mut held: Option<git::RepoStatus> = None;
    let mut first_error: Option<anyhow::Error> = None;
    for scope in &scopes {
        let status = tokio::select! {
            biased;
            _ = cancel.cancelled() => return Ok(()),
            status = git::repo_status(&cache, scope, force) => status,
        };
        let status = match status {
            Ok(status) => status,
            Err(error) => {
                debug_log!("git status failed for {:?}: {error}", scope.repo_root);
                first_error.get_or_insert(error);
                continue;
            }
        };
        if let Some(previous) = held.replace(status)
            && !send_event_unless_cancelled(&out, &git_status_event(id, &previous, false), &cancel)
                .await?
        {
            return Ok(());
        }
    }

    match held {
        Some(final_status) => {
            send_event_unless_cancelled(&out, &git_status_event(id, &final_status, true), &cancel)
                .await?;
            Ok(())
        }
        None => {
            Err(first_error.unwrap_or_else(|| anyhow::anyhow!("git status produced no result")))
        }
    }
}

fn git_status_event(id: u64, status: &git::RepoStatus, done: bool) -> Event {
    Event::GitStatus {
        id,
        repo_root: status.repo_root.to_string_lossy().into_owned(),
        statuses: status.statuses.as_ref().clone(),
        done,
        truncated: status.truncated,
    }
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

#[cfg(test)]
mod tests {
    use super::*;

    /// The whole point of `finish_request_task` — and of the doc comment on it.
    ///
    /// This assertion is only meaningful while the shipped binary unwinds; the
    /// manifest test below is the other half, because a `cargo test` run can
    /// never observe the release profile's panic strategy on its own.
    #[tokio::test]
    async fn a_panicked_request_task_does_not_take_the_daemon_down() {
        let mut tasks: JoinSet<Result<()>> = JoinSet::new();
        tasks.spawn(async { panic!("a request handler hit an internal assertion") });
        let completed = tasks.join_next().await.expect("the task must complete");
        assert!(
            completed.as_ref().is_err_and(JoinError::is_panic),
            "a panic must arrive as a JoinError, not as process death"
        );
        finish_request_task(completed);

        // And the daemon is still able to run the next request.
        tasks.spawn(async { Ok(()) });
        finish_request_task(tasks.join_next().await.expect("the next task"));
    }

    /// `install-common.sh` builds `--release`, so the profile decides whether
    /// the containment above exists at all: under `panic = "abort"` the process
    /// dies at the panic site, `JoinError::is_panic` is unreachable, and the
    /// test above passes anyway because `cargo test` builds the dev profile.
    #[test]
    fn the_release_profile_keeps_panics_unwinding() {
        let manifest = include_str!("../../Cargo.toml");
        let release = manifest
            .split("[profile.release]")
            .nth(1)
            .expect("a [profile.release] section");
        let release = release.split("\n[").next().unwrap_or(release);
        for line in release.lines() {
            let line = line.trim();
            if line.starts_with('#') {
                continue;
            }
            assert!(
                !line.starts_with("panic"),
                "[profile.release] sets {line:?}: per-request panic containment \
                 is dead code in the shipped binary unless panics unwind"
            );
        }
    }

    /// The self-test used to re-derive its own answer, so no edit to the real
    /// handshake could make it fail. It now drives the request loop.
    #[tokio::test]
    async fn the_self_test_round_trips_the_real_handshake() {
        self_test().await.expect("the built-in self-test must pass");
    }

    /// A capability that stops being announced must fail the self-test. The
    /// handshake is built in one place now, so this asserts the loop's reply
    /// and `handshake_event` cannot disagree about it.
    #[tokio::test]
    async fn the_handshake_announces_every_optional_capability_it_has() {
        let Event::Pong { capabilities, .. } = handshake_event(1, true, true) else {
            panic!("handshake_event must produce a pong");
        };
        for required in BASE_CAPABILITIES
            .iter()
            .chain(["search", "fs-ops", "watch", "git-status"].iter())
        {
            assert!(capabilities.contains(required), "{required} went missing");
        }

        let Event::Pong { capabilities, .. } = handshake_event(1, false, false) else {
            panic!("handshake_event must produce a pong");
        };
        assert!(!capabilities.contains(&"watch"));
        assert!(!capabilities.contains(&"git-status"));
    }

    /// A record with no newline must not grow the daemon without bound, and the
    /// stream must resume at the next well-formed request.
    #[tokio::test]
    async fn an_oversized_request_costs_one_error_and_not_the_stream() {
        let oversized = "x".repeat(MAX_REQUEST_LINE_BYTES + 1);
        let input = format!(
            "{oversized}\n{}\n",
            serde_json::json!({"type": "ping", "id": 5})
        );
        let (mut client, server) = tokio::io::duplex(64 * 1024);
        run(input.as_bytes(), server).await.expect("daemon loop");

        let mut reply = String::new();
        tokio::io::AsyncReadExt::read_to_string(&mut client, &mut reply)
            .await
            .expect("read replies");
        let events: Vec<serde_json::Value> = reply
            .lines()
            .map(|line| serde_json::from_str(line).expect("JSON event"))
            .collect();
        assert_eq!(events[0]["type"], "error");
        assert!(
            events[0]["message"]
                .as_str()
                .expect("message")
                .contains("exceeds"),
            "{events:?}"
        );
        assert_eq!(events[1]["type"], "pong", "{events:?}");
        assert_eq!(events[1]["id"], 5);
    }
}
