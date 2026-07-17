use anyhow::{Context, Result, anyhow, bail};
use ignore::WalkBuilder;
use serde::{Deserialize, Serialize};
use std::{
    cmp::Ordering,
    collections::HashMap,
    fs,
    path::{Path, PathBuf},
    sync::Arc,
    time::Instant,
};
use tokio::{
    io::{AsyncBufReadExt, AsyncWriteExt, BufReader, BufWriter},
    sync::{Mutex, Semaphore, mpsc},
    task::{JoinError, JoinSet},
};
use tokio_util::sync::CancellationToken;

const DEFAULT_PAGE_SIZE: usize = 200;
const MAX_PAGE_SIZE: usize = 1_000;
const MAX_ACTIVE_REQUESTS: usize = 64;
const MAX_CONCURRENT_SCANS: usize = 8;
const OUTPUT_CHANNEL_CAPACITY: usize = 64;
const PROTOCOL_VERSION: u32 = 1;
const CAPABILITIES: &[&str] = &[
    "list",
    "cancel",
    "ping",
    "chunked-results",
    "git-ignore",
    "hidden-files",
];

macro_rules! debug_log {
    ($($arg:tt)*) => {
        if cfg!(debug_assertions) {
            eprintln!($($arg)*);
        }
    };
}

#[derive(Debug, Deserialize)]
#[serde(tag = "type")]
enum Request {
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
    },
    #[serde(rename = "cancel")]
    Cancel { id: u64 },
    #[serde(rename = "ping")]
    Ping { id: u64 },
}

fn default_page() -> usize {
    DEFAULT_PAGE_SIZE
}

fn default_git_ignore() -> bool {
    true
}

fn normalize_page(page: usize) -> usize {
    page.clamp(1, MAX_PAGE_SIZE)
}

#[derive(Debug, Serialize)]
#[serde(tag = "type")]
enum Event {
    #[serde(rename = "list_chunk")]
    ListChunk {
        id: u64,
        entries: Vec<Entry>,
        done: bool,
    },
    #[serde(rename = "error")]
    Error { id: u64, message: String },
    #[serde(rename = "pong")]
    Pong {
        id: u64,
        protocol_version: u32,
        daemon_version: &'static str,
        capabilities: &'static [&'static str],
    },
}

#[derive(Debug, Serialize)]
struct Entry {
    name: String,
    path: String,
    is_dir: bool,
}

#[derive(Clone)]
struct ActiveRequest {
    generation: u64,
    cancel: CancellationToken,
}

type ActiveRequests = Arc<Mutex<HashMap<u64, ActiveRequest>>>;
type EventTx = mpsc::Sender<String>;

/// Replace an active request with the same ID and cancel the superseded work.
/// Returns false only when a new ID would exceed the active-request limit.
fn activate_request(
    requests: &mut HashMap<u64, ActiveRequest>,
    id: u64,
    generation: u64,
    cancel: CancellationToken,
) -> bool {
    if !requests.contains_key(&id) && requests.len() >= MAX_ACTIVE_REQUESTS {
        return false;
    }

    if let Some(previous) = requests.insert(id, ActiveRequest { generation, cancel }) {
        previous.cancel.cancel();
    }
    true
}

/// A superseded task must not remove the newer request that reused its ID.
fn remove_active_if_generation(
    requests: &mut HashMap<u64, ActiveRequest>,
    id: u64,
    generation: u64,
) -> bool {
    if requests
        .get(&id)
        .is_some_and(|active| active.generation == generation)
    {
        requests.remove(&id);
        true
    } else {
        false
    }
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
                "simpletree-daemon {}\n\nUSAGE:\n    simpletree-daemon\n    simpletree-daemon --version\n\nThe default mode reads one JSON request per line from stdin and writes one JSON event per line to stdout.",
                env!("CARGO_PKG_VERSION")
            );
            Ok(true)
        }
        _ => bail!("unknown command-line argument: {arg}"),
    }
}

/// Serialize stdout writes and coalesce queued records into one flush.
async fn stdout_writer(mut rx: mpsc::Receiver<String>) -> std::io::Result<()> {
    let mut out = BufWriter::new(tokio::io::stdout());
    while let Some(line) = rx.recv().await {
        out.write_all(line.as_bytes()).await?;
        out.write_all(b"\n").await?;

        while let Ok(line) = rx.try_recv() {
            out.write_all(line.as_bytes()).await?;
            out.write_all(b"\n").await?;
        }
        out.flush().await?;
    }
    out.flush().await
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
    let scan_slots = Arc::new(Semaphore::new(MAX_CONCURRENT_SCANS));
    let mut tasks: JoinSet<Result<()>> = JoinSet::new();
    let mut next_generation = 0_u64;

    loop {
        tokio::select! {
            completed = tasks.join_next(), if !tasks.is_empty() => {
                if let Some(completed) = completed {
                    finish_request_task(completed)?;
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
                                capabilities: CAPABILITIES,
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
                    } => {
                        next_generation = next_generation.wrapping_add(1);
                        if next_generation == 0 {
                            next_generation = 1;
                        }
                        let generation = next_generation;
                        let cancel = CancellationToken::new();
                        let accepted = {
                            let mut requests = active.lock().await;
                            activate_request(
                                &mut requests,
                                id,
                                generation,
                                cancel.clone(),
                            )
                        };

                        if !accepted {
                            send_event(
                                &out_tx,
                                &Event::Error {
                                    id,
                                    message: format!(
                                        "too many active requests (limit {MAX_ACTIVE_REQUESTS})"
                                    ),
                                },
                            )
                            .await?;
                            continue;
                        }

                        tasks.spawn(run_list_request(
                            id,
                            generation,
                            PathBuf::from(path),
                            show_hidden,
                            git_ignore,
                            normalize_page(max),
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
                }
            }
        }
    }

    // EOF means no more requests, but accepted work and queued protocol records
    // must finish before the process exits.
    while let Some(completed) = tasks.join_next().await {
        finish_request_task(completed)?;
    }
    drop(out_tx);
    writer.await.context("stdout writer task failed")??;
    Ok(())
}

fn finish_request_task(completed: std::result::Result<Result<()>, JoinError>) -> Result<()> {
    completed.context("request task failed")??;
    Ok(())
}

fn best_effort_request_id(line: &str) -> u64 {
    serde_json::from_str::<serde_json::Value>(line)
        .ok()
        .and_then(|value| value.get("id").and_then(serde_json::Value::as_u64))
        .unwrap_or(0)
}

#[allow(clippy::too_many_arguments)]
async fn run_list_request(
    id: u64,
    generation: u64,
    path: PathBuf,
    show_hidden: bool,
    git_ignore: bool,
    page: usize,
    out: EventTx,
    cancel: CancellationToken,
    active: ActiveRequests,
    scan_slots: Arc<Semaphore>,
) -> Result<()> {
    let result = handle_list(
        id,
        path,
        show_hidden,
        git_ignore,
        page,
        out.clone(),
        cancel.clone(),
        scan_slots,
    )
    .await;

    let delivery = match result {
        Ok(()) => Ok(()),
        Err(_) if cancel.is_cancelled() => Ok(()),
        Err(error) => {
            let event = Event::Error {
                id,
                message: error.to_string(),
            };
            send_event_unless_cancelled(&out, &event, &cancel)
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
async fn handle_list(
    id: u64,
    path: PathBuf,
    show_hidden: bool,
    git_ignore: bool,
    page: usize,
    out: EventTx,
    cancel: CancellationToken,
    scan_slots: Arc<Semaphore>,
) -> Result<()> {
    let _permit = tokio::select! {
        biased;
        _ = cancel.cancelled() => return Ok(()),
        permit = scan_slots.acquire_owned() => permit.context("directory scan limiter closed")?,
    };

    debug_log!("handle_list start id={id} path={path:?}");
    let started = Instant::now();
    let scan_cancel = cancel.clone();
    let entries = tokio::task::spawn_blocking(move || {
        scan_directory(&path, show_hidden, git_ignore, &scan_cancel)
    })
    .await
    .context("directory scanner task failed")??;

    debug_log!(
        "handle_list done id={id} entries={} elapsed_ms={}",
        entries.len(),
        started.elapsed().as_millis()
    );
    if cancel.is_cancelled() {
        return Ok(());
    }

    emit_entries(id, entries, page, &out, &cancel).await
}

fn scan_directory(
    path: &Path,
    show_hidden: bool,
    git_ignore: bool,
    cancel: &CancellationToken,
) -> Result<Vec<Entry>> {
    let metadata = fs::metadata(path)
        .with_context(|| format!("failed to inspect directory: {}", path.display()))?;
    if !metadata.is_dir() {
        bail!("not a directory: {}", path.display());
    }
    fs::read_dir(path).with_context(|| format!("failed to read directory: {}", path.display()))?;

    let mut builder = WalkBuilder::new(path);
    builder
        .follow_links(false)
        .hidden(!show_hidden)
        .git_ignore(git_ignore)
        .git_global(git_ignore)
        .git_exclude(git_ignore)
        .parents(git_ignore)
        .max_depth(Some(1));

    let mut entries = Vec::new();
    for dent in builder.build() {
        if cancel.is_cancelled() {
            return Ok(Vec::new());
        }

        let dent =
            dent.map_err(|error| anyhow!("failed to scan directory {}: {error}", path.display()))?;
        if dent.depth() == 0 {
            continue;
        }

        let entry_path = dent.path().to_path_buf();
        let Some(name) = entry_path.file_name().and_then(|name| name.to_str()) else {
            continue;
        };
        let is_dir = match dent.file_type() {
            Some(kind) if kind.is_dir() => true,
            Some(kind) if kind.is_symlink() => {
                fs::metadata(&entry_path).is_ok_and(|metadata| metadata.is_dir())
            }
            Some(_) => false,
            None => fs::metadata(&entry_path).is_ok_and(|metadata| metadata.is_dir()),
        };
        entries.push(Entry {
            name: name.to_owned(),
            path: entry_path.to_string_lossy().into_owned(),
            is_dir,
        });
    }

    Ok(sort_entries(entries))
}

fn sort_entries(entries: Vec<Entry>) -> Vec<Entry> {
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

async fn emit_entries(
    id: u64,
    entries: Vec<Entry>,
    page: usize,
    out: &EventTx,
    cancel: &CancellationToken,
) -> Result<()> {
    let page = normalize_page(page);
    if entries.is_empty() {
        let event = Event::ListChunk {
            id,
            entries: Vec::new(),
            done: true,
        };
        send_event_unless_cancelled(out, &event, cancel).await?;
        return Ok(());
    }

    let mut entries = entries.into_iter();
    while !entries.as_slice().is_empty() {
        let remaining = entries.len();
        let chunk: Vec<Entry> = entries.by_ref().take(page).collect();
        let event = Event::ListChunk {
            id,
            done: chunk.len() == remaining,
            entries: chunk,
        };
        if !send_event_unless_cancelled(out, &event, cancel).await? {
            break;
        }
    }
    Ok(())
}

async fn send_event_unless_cancelled(
    out: &EventTx,
    event: &Event,
    cancel: &CancellationToken,
) -> Result<bool> {
    tokio::select! {
        biased;
        _ = cancel.cancelled() => Ok(false),
        result = send_event(out, event) => {
            result?;
            Ok(true)
        }
    }
}

async fn send_event(out: &EventTx, event: &Event) -> Result<()> {
    let line = serde_json::to_string(event).context("failed to serialize protocol event")?;
    out.send(line)
        .await
        .map_err(|_| anyhow!("stdout writer stopped"))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entry(name: &str, is_dir: bool) -> Entry {
        Entry {
            name: name.to_owned(),
            path: format!("/tmp/{name}"),
            is_dir,
        }
    }

    #[test]
    fn page_size_is_always_bounded_and_nonzero() {
        assert_eq!(normalize_page(0), 1);
        assert_eq!(normalize_page(1), 1);
        assert_eq!(normalize_page(DEFAULT_PAGE_SIZE), DEFAULT_PAGE_SIZE);
        assert_eq!(normalize_page(usize::MAX), MAX_PAGE_SIZE);
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

    #[test]
    fn replacing_an_id_cancels_old_work_and_old_cleanup_is_safe() {
        let mut requests = HashMap::new();
        let old_cancel = CancellationToken::new();
        let new_cancel = CancellationToken::new();

        assert!(activate_request(&mut requests, 7, 1, old_cancel.clone()));
        assert!(activate_request(&mut requests, 7, 2, new_cancel.clone()));
        assert!(old_cancel.is_cancelled());
        assert!(!new_cancel.is_cancelled());

        assert!(!remove_active_if_generation(&mut requests, 7, 1));
        assert_eq!(requests.get(&7).map(|active| active.generation), Some(2));
        assert!(remove_active_if_generation(&mut requests, 7, 2));
        assert!(!requests.contains_key(&7));
    }

    #[test]
    fn capabilities_include_the_core_protocol_operations() {
        assert!(CAPABILITIES.contains(&"list"));
        assert!(CAPABILITIES.contains(&"cancel"));
        assert!(CAPABILITIES.contains(&"ping"));
    }
}
