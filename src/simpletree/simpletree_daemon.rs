use anyhow::Result;
use ignore::WalkBuilder;
use serde::{Deserialize, Serialize};
use std::{collections::HashMap, path::PathBuf, sync::Arc};
use tokio::{
    io::{AsyncBufReadExt, AsyncWriteExt, BufReader},
    sync::Mutex,
};
use tokio_util::sync::CancellationToken;

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
}

fn default_page() -> usize {
    200
}

fn default_git_ignore() -> bool {
    true
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
}

#[derive(Debug, Serialize)]
struct Entry {
    name: String,
    path: String,
    is_dir: bool,
}

/// 专用 stdout 写入者：通过 mpsc channel 串行化所有输出，避免 Mutex 争用
async fn stdout_writer(mut rx: tokio::sync::mpsc::Receiver<String>) {
    let mut out = tokio::io::stdout();
    while let Some(line) = rx.recv().await {
        if out.write_all(line.as_bytes()).await.is_err() {
            break;
        }
        if out.write_all(b"\n").await.is_err() {
            break;
        }
        let _ = out.flush().await;
    }
}

type EventTx = tokio::sync::mpsc::Sender<String>;

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<()> {
    let stdin = BufReader::new(tokio::io::stdin());
    let mut lines = stdin.lines();
    debug_log!("start");

    // stdout 写入 channel（容量足够大避免阻塞扫描任务）
    let (out_tx, out_rx) = tokio::sync::mpsc::channel::<String>(4096);
    tokio::spawn(stdout_writer(out_rx));

    // 任务取消表：id -> token
    let cancels: Arc<Mutex<HashMap<u64, CancellationToken>>> =
        Arc::new(Mutex::new(HashMap::new()));

    while let Some(line) = lines.next_line().await? {
        if line.trim().is_empty() {
            continue;
        }
        debug_log!("REQ LINE: {line}");
        let req = match serde_json::from_str::<Request>(&line) {
            Ok(r) => r,
            Err(e) => {
                debug_log!("REQ PARSE ERR: {e}");
                send_event(
                    &out_tx,
                    &Event::Error {
                        id: 0,
                        message: format!("invalid request: {e}"),
                    },
                )
                .await;
                continue;
            }
        };
        debug_log!("REQ DECODED: {:?}", req);

        match req {
            Request::List {
                id,
                path,
                show_hidden,
                git_ignore,
                max,
            } => {
                let path = PathBuf::from(path);
                let tx = out_tx.clone();
                let cancels_clone = cancels.clone();

                // 建立取消 token
                let token = CancellationToken::new();
                {
                    let mut map = cancels.lock().await;
                    map.insert(id, token.clone());
                }

                tokio::spawn(async move {
                    let res =
                        handle_list(id, path, show_hidden, git_ignore, max, tx.clone(), token.clone()).await;
                    if let Err(e) = res {
                        send_event(
                            &tx,
                            &Event::Error {
                                id,
                                message: e.to_string(),
                            },
                        )
                        .await;
                    }
                    // 结束后移除取消 token
                    let mut map = cancels_clone.lock().await;
                    map.remove(&id);
                });
            }
            Request::Cancel { id } => {
                let maybe = {
                    let map = cancels.lock().await;
                    map.get(&id).cloned()
                };
                if let Some(tok) = maybe {
                    tok.cancel();
                }
            }
        }
    }

    Ok(())
}

async fn handle_list(
    id: u64,
    path: PathBuf,
    show_hidden: bool,
    git_ignore: bool,
    page: usize,
    out: EventTx,
    cancel: CancellationToken,
) -> Result<()> {
    debug_log!("handle_list start id={id} path={:?}", path);
    let cancel_clone = cancel.clone();
    let scan_path = path.clone();

    // 在阻塞线程中完成扫描 + 排序，避免 channel 开销
    let mut entries: Vec<Entry> = tokio::task::spawn_blocking(move || {
        let mut wb = WalkBuilder::new(&scan_path);
        wb.follow_links(false)
            .hidden(!show_hidden)
            .git_ignore(git_ignore)
            .git_global(git_ignore)
            .git_exclude(git_ignore)
            .parents(git_ignore)
            .max_depth(Some(1));
        let walker = wb.build();

        let mut keyed: Vec<(String, Entry)> = Vec::with_capacity(512);
        for dent in walker {
            if cancel_clone.is_cancelled() {
                return keyed.into_iter().map(|(_, e)| e).collect();
            }
            match dent {
                Ok(d) => {
                    if d.depth() == 0 {
                        continue;
                    }
                    let p = d.path().to_path_buf();
                    if let Some(name) = p.file_name().and_then(|s| s.to_str()) {
                        let is_dir = d
                            .metadata()
                            .map(|m| m.is_dir())
                            .unwrap_or_else(|_| p.is_dir());
                        let sort_key = name.to_lowercase();
                        keyed.push((sort_key, Entry {
                            name: name.to_string(),
                            path: p.to_string_lossy().into_owned(),
                            is_dir,
                        }));
                    }
                }
                Err(_) => {}
            }
        }

        // 目录优先 + 名称不区分大小写排序（预计算 sort key，避免重复分配）
        keyed.sort_by(|a, b| match (a.1.is_dir, b.1.is_dir) {
            (true, false) => std::cmp::Ordering::Less,
            (false, true) => std::cmp::Ordering::Greater,
            _ => a.0.cmp(&b.0),
        });
        keyed.into_iter().map(|(_, e)| e).collect()
    })
    .await?;

    debug_log!("handle_list done id={id} entries={}", entries.len());

    if cancel.is_cancelled() {
        return Ok(());
    }

    // 分块输出
    if entries.is_empty() {
        send_event(
            &out,
            &Event::ListChunk {
                id,
                entries: vec![],
                done: true,
            },
        )
        .await;
        return Ok(());
    }

    let total = entries.len();
    let mut i = 0usize;
    while i < total {
        if cancel.is_cancelled() {
            break;
        }
        let end = (i + page).min(total);
        let done = end >= total;
        // drain 从前端取走所有权，避免 to_vec() 克隆
        let chunk: Vec<Entry> = entries.drain(..end - i).collect();
        i = end;
        send_event(
            &out,
            &Event::ListChunk {
                id,
                entries: chunk,
                done,
            },
        )
        .await;
    }
    Ok(())
}

async fn send_event(out: &EventTx, evt: &Event) {
    let line = serde_json::to_string(evt).unwrap();
    let _ = out.send(line).await;
}
