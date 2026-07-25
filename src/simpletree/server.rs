use crate::protocol::{Event, MAX_ACTIVE_REQUESTS};
use anyhow::{Context, Result, anyhow};
use std::collections::HashMap;
use std::sync::Arc;
use tokio::{
    io::{AsyncWriteExt, BufWriter},
    sync::{Mutex, mpsc},
};
use tokio_util::sync::CancellationToken;

#[derive(Clone)]
pub struct ActiveRequest {
    pub generation: u64,
    pub cancel: CancellationToken,
}

pub type ActiveRequests = Arc<Mutex<HashMap<u64, ActiveRequest>>>;
pub type EventTx = mpsc::Sender<String>;

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
pub async fn stdout_writer(mut rx: mpsc::Receiver<String>) -> std::io::Result<()> {
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

pub async fn send_event(out: &EventTx, event: &Event) -> Result<()> {
    let line = serde_json::to_string(event).context("failed to serialize protocol event")?;
    out.send(line)
        .await
        .map_err(|_| anyhow!("stdout writer stopped"))
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

#[cfg(test)]
mod tests {
    use super::*;

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
}
