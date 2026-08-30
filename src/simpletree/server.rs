use crate::protocol::{Event, MAX_ACTIVE_REQUESTS};
use anyhow::{Context, Result, anyhow};
use std::collections::HashMap;
use std::sync::{
    Arc,
    atomic::{AtomicBool, Ordering},
};
use std::time::Duration;
use tokio::{
    io::{AsyncBufRead, AsyncBufReadExt, AsyncWrite, AsyncWriteExt, BufWriter},
    sync::{Mutex, Notify, mpsc},
};
use tokio_util::sync::CancellationToken;

/// How long a producer may wait for room in the stdout queue before the whole
/// output path is declared dead.
const EVENT_SEND_TIMEOUT: Duration = Duration::from_secs(2);

#[derive(Clone)]
pub struct ActiveRequest {
    pub generation: u64,
    pub cancel: CancellationToken,
}

pub type ActiveRequests = Arc<Mutex<HashMap<u64, ActiveRequest>>>;

#[derive(Debug)]
pub struct EventSendError;

/// Shared, ordered path from every daemon producer to Vim's stdout writer.
///
/// This used to be the raw bounded sender, so every producer could wait on it
/// forever.  simpletree is the most exposed daemon in the family for that: its
/// queue holds 64 records, one list or search request emits many chunk events,
/// the watch service pushes unsolicited events into the same queue from a
/// debounce task, and the request loop itself answers Ping/Watch/Unwatch and
/// every parse error inline.  A client that stopped reading stdout therefore
/// wedged the loop *before* it could reach the next stdin read, so closing
/// stdin did not free it either.
///
/// Every send now carries the same deadline and trips one shared fail-closed
/// bit; `wait_stalled` lets the request loop notice that bit while it is
/// parked on the stdin read rather than only between records.  This is
/// simplecc's `EventTx`, which was written for exactly this failure.
#[derive(Clone)]
pub struct EventTx {
    sender: mpsc::Sender<String>,
    stalled: Arc<AtomicBool>,
    stalled_notify: Arc<Notify>,
}

impl EventTx {
    pub fn new(sender: mpsc::Sender<String>) -> Self {
        EventTx {
            sender,
            stalled: Arc::new(AtomicBool::new(false)),
            stalled_notify: Arc::new(Notify::new()),
        }
    }

    pub fn is_stalled(&self) -> bool {
        self.stalled.load(Ordering::Acquire)
    }

    pub fn mark_stalled(&self) {
        if !self.stalled.swap(true, Ordering::AcqRel) {
            // notify_one stores a permit when the stdin waiter has created but
            // not yet polled its Notified future; notify_waiters would lose
            // that transition in precisely that window.
            self.stalled_notify.notify_one();
        }
    }

    pub async fn wait_stalled(&self) {
        loop {
            // Register before checking the bit so a transition between the
            // check and the await cannot be lost.
            let notified = self.stalled_notify.notified();
            if self.is_stalled() {
                return;
            }
            notified.await;
        }
    }

    pub async fn send(&self, line: String) -> std::result::Result<(), EventSendError> {
        if self.is_stalled() {
            return Err(EventSendError);
        }
        match tokio::time::timeout(EVENT_SEND_TIMEOUT, self.sender.send(line)).await {
            Ok(Ok(())) => Ok(()),
            Ok(Err(_)) | Err(_) => {
                self.mark_stalled();
                Err(EventSendError)
            }
        }
    }
}

/// Replace an active request with the same ID and cancel the superseded work.
/// Returns false only when a new ID would exceed the active-request limit.
pub fn activate_request(
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
pub fn remove_active_if_generation(
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

/// Serialize stdout writes and coalesce queued records into one flush.
pub async fn stdout_writer<W>(mut rx: mpsc::Receiver<String>, sink: W) -> std::io::Result<()>
where
    W: AsyncWrite + Unpin,
{
    let mut out = BufWriter::new(sink);
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

pub async fn send_event(out: &EventTx, event: &Event) -> Result<()> {
    let line = serde_json::to_string(event).context("failed to serialize protocol event")?;
    out.send(line)
        .await
        .map_err(|_| anyhow!("stdout writer stopped or stalled"))
}

pub async fn send_event_unless_cancelled(
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

/// Turn one accumulated record into a request line, or say why it is not one.
fn finish_request_line(mut bytes: Vec<u8>, too_long: bool, limit: usize) -> Result<String, String> {
    if bytes.last() == Some(&b'\r') {
        bytes.pop();
    }
    if too_long || bytes.len() > limit {
        return Err(format!("request line exceeds {limit} bytes"));
    }
    String::from_utf8(bytes).map_err(|_| "request line is not valid UTF-8".to_string())
}

/// Bounded reader for the JSONL request stream.
///
/// `AsyncBufReadExt::lines()` grows one `String` until the next newline
/// arrives: a Vim channel that dies mid-write, or any producer that loses its
/// newline, grows the daemon until the machine runs out of memory, and the
/// record is materialised before anything gets to reject it.  This is
/// simplefinder's reader — it decides on the size *before* materialising, and
/// after rejecting an oversized record it resumes exactly at the next newline,
/// so one bad record costs one error event instead of desynchronising the
/// stream.
///
/// The one adaptation: the accumulator lives in this struct rather than inside
/// the future, the way tokio's own `Lines` keeps its buffer, because
/// simpletree's request loop races the read against `JoinSet::join_next` in a
/// `select!`.  A partial record held inside a dropped future would be lost
/// after `consume` had already taken it off the reader — which is the same
/// desynchronisation the bounded reader exists to prevent.
pub struct RequestReader<R> {
    reader: R,
    bytes: Vec<u8>,
    too_long: bool,
    limit: usize,
}

impl<R> RequestReader<R>
where
    R: AsyncBufRead + Unpin,
{
    pub fn new(reader: R, limit: usize) -> Self {
        RequestReader {
            reader,
            bytes: Vec::new(),
            too_long: false,
            limit,
        }
    }

    /// `Ok(None)` at end of stream; `Ok(Some(Err(_)))` for a record that is
    /// too long or not UTF-8, which the caller reports and then carries on.
    pub async fn next_line(&mut self) -> std::io::Result<Option<Result<String, String>>> {
        let RequestReader {
            reader,
            bytes,
            too_long,
            limit,
        } = self;

        loop {
            let available = reader.fill_buf().await?;
            if available.is_empty() {
                return if bytes.is_empty() && !*too_long {
                    Ok(None)
                } else {
                    Ok(Some(finish_request_line(
                        std::mem::take(bytes),
                        std::mem::replace(too_long, false),
                        *limit,
                    )))
                };
            }

            let newline = available.iter().position(|byte| *byte == b'\n');
            let content_len = newline.unwrap_or(available.len());
            let consumed = newline.map_or(available.len(), |position| position + 1);

            if !*too_long {
                // Keep one extra byte until the record ends: for CRLF that byte
                // is the framing CR, not part of the JSON line's documented
                // limit.
                if bytes.len().saturating_add(content_len) > limit.saturating_add(1) {
                    bytes.clear();
                    *too_long = true;
                } else {
                    bytes.extend_from_slice(&available[..content_len]);
                }
            }
            reader.consume(consumed);

            if newline.is_some() {
                return Ok(Some(finish_request_line(
                    std::mem::take(bytes),
                    std::mem::replace(too_long, false),
                    *limit,
                )));
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::BufReader;

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
    fn new_ids_are_rejected_once_the_active_limit_is_reached() {
        let mut requests = HashMap::new();
        for id in 0..MAX_ACTIVE_REQUESTS as u64 {
            assert!(activate_request(
                &mut requests,
                id,
                1,
                CancellationToken::new()
            ));
        }
        assert!(!activate_request(
            &mut requests,
            MAX_ACTIVE_REQUESTS as u64,
            1,
            CancellationToken::new()
        ));
        // Reusing an existing id is still allowed at the limit.
        assert!(activate_request(
            &mut requests,
            0,
            2,
            CancellationToken::new()
        ));
    }

    /// The record that blows the limit must cost exactly itself: the reader
    /// resumes at the next newline and the following request still parses.
    #[tokio::test]
    async fn the_bounded_reader_recovers_at_the_next_record() {
        let input = b"0123456789\n{\"type\":\"ping\",\"id\":7}\r\n";
        let mut reader = RequestReader::new(BufReader::new(&input[..]), 8);

        let oversized = reader
            .next_line()
            .await
            .unwrap()
            .unwrap()
            .expect_err("a ten-byte record must not pass an eight-byte limit");
        assert_eq!(oversized, "request line exceeds 8 bytes");

        reader.limit = 64;
        assert_eq!(
            reader.next_line().await.unwrap().unwrap().unwrap(),
            r#"{"type":"ping","id":7}"#
        );
        assert!(reader.next_line().await.unwrap().is_none());
    }

    /// A record exactly at the limit is legal, and the CRLF framing CR is not
    /// charged against it.
    #[tokio::test]
    async fn a_record_at_the_limit_is_accepted_with_crlf_framing() {
        let mut reader = RequestReader::new(BufReader::new(&b"12345678\r\n"[..]), 8);
        assert_eq!(
            reader.next_line().await.unwrap().unwrap().unwrap(),
            "12345678"
        );
    }

    /// The reason for the struct: simpletree reads inside a `select!` whose
    /// other arm keeps the loop running, so a partial record must survive the
    /// read future being dropped.  Reading a record one byte at a time through
    /// repeatedly-cancelled futures must still yield that record.
    #[tokio::test]
    async fn a_partial_record_survives_a_cancelled_read() {
        let (mut client, server) = tokio::io::duplex(64);
        let mut reader = RequestReader::new(BufReader::new(server), 64);

        for byte in br#"{"type":"ping","id":3}"# {
            client.write_all(&[*byte]).await.unwrap();
            // Every byte is delivered to a future that is then thrown away.
            assert!(
                tokio::time::timeout(Duration::from_millis(20), reader.next_line())
                    .await
                    .is_err(),
                "no newline has arrived yet"
            );
        }
        client.write_all(b"\n").await.unwrap();
        assert_eq!(
            reader.next_line().await.unwrap().unwrap().unwrap(),
            r#"{"type":"ping","id":3}"#
        );
    }

    /// A consumer that never reads must not park a producer for ever: the send
    /// gives up on its deadline, trips the shared bit, and every later send
    /// fails immediately instead of waiting again.
    #[tokio::test]
    async fn a_full_queue_stalls_instead_of_waiting_for_ever() {
        let (sender, _rx) = mpsc::channel::<String>(1);
        let out = EventTx::new(sender);
        out.send("first".to_owned()).await.expect("queue has room");

        let waiter = out.clone();
        let observed = tokio::spawn(async move { waiter.wait_stalled().await });

        // The receiver is alive and never reads, which is exactly the wedge:
        // before the deadline this send never returned.
        let started = std::time::Instant::now();
        assert!(
            tokio::time::timeout(EVENT_SEND_TIMEOUT * 4, out.send("second".to_owned()))
                .await
                .expect("the send must observe its own deadline")
                .is_err()
        );
        assert!(started.elapsed() >= EVENT_SEND_TIMEOUT);
        assert!(out.is_stalled());

        // Fail-closed: no later send may pay the deadline again.
        let started = std::time::Instant::now();
        assert!(out.send("third".to_owned()).await.is_err());
        assert!(started.elapsed() < EVENT_SEND_TIMEOUT);

        // And a loop parked on the stdin read learns about it without needing
        // another record to arrive.
        tokio::time::timeout(Duration::from_secs(5), observed)
            .await
            .expect("wait_stalled must wake")
            .expect("waiter task");
    }
}
