use super::*;

#[derive(Debug)]
pub enum ReplayError {
    CursorExpired,
    CursorInFuture,
    EventTooLarge(i64),
    Database(rusqlite::Error),
}

impl From<rusqlite::Error> for ReplayError {
    fn from(error: rusqlite::Error) -> Self {
        Self::Database(error)
    }
}

pub struct ReplaySnapshot {
    pub replay_after: i64,
    pub high_watermark: i64,
    pub live_after: i64,
}

/// Snapshot cursor bounds and high-water state; filter every replayed row separately against its current viewer.
pub fn retained_public_after(
    conn: &Connection,
    cursor: Option<i64>,
) -> Result<ReplaySnapshot, ReplayError> {
    let (earliest, latest): (Option<i64>, Option<i64>) = conn.query_row(
        "SELECT MIN(sequence), MAX(sequence) FROM events",
        [],
        |row| Ok((row.get(0)?, row.get(1)?)),
    )?;
    let high_watermark = latest.unwrap_or(0);

    if let Some(cursor) = cursor {
        if cursor > high_watermark {
            return Err(ReplayError::CursorInFuture);
        }
        if earliest.is_some_and(|first| cursor.saturating_add(1) < first) {
            return Err(ReplayError::CursorExpired);
        }
    }

    let Some(cursor) = cursor else {
        return Ok(ReplaySnapshot {
            replay_after: high_watermark,
            high_watermark,
            // Preserve subscribed events that race the snapshot query.
            live_after: 0,
        });
    };

    Ok(ReplaySnapshot {
        replay_after: cursor,
        high_watermark,
        live_after: high_watermark,
    })
}

pub(super) struct ReplayBatch {
    pub(super) envelopes: VecDeque<Value>,
    pub(super) scanned_through: i64,
}

pub(super) fn retained_visible_batch(
    conn: &Connection,
    after: i64,
    high_watermark: i64,
    viewer: &Viewer,
) -> Result<ReplayBatch, ReplayError> {
    let mut statement = conn.prepare(
        "SELECT sequence, event_id, occurred_at, node_id, cluster_id,
                operation_id, event_type, severity, visibility_json, payload_json,
                length(CAST(payload_json AS BLOB)),
                length(CAST(visibility_json AS BLOB)),
                length(CAST(event_id AS BLOB))
                  + length(CAST(occurred_at AS BLOB))
                  + length(CAST(node_id AS BLOB))
                  + length(CAST(COALESCE(cluster_id, '') AS BLOB))
                  + length(CAST(COALESCE(operation_id, '') AS BLOB))
                  + length(CAST(event_type AS BLOB))
                  + length(CAST(severity AS BLOB))
         FROM events
         WHERE sequence > ?1 AND sequence <= ?2
         ORDER BY sequence ASC
         LIMIT ?3",
    )?;
    let mut rows = statement.query(rusqlite::params![after, high_watermark, REPLAY_BATCH_SIZE])?;

    let mut envelopes = VecDeque::new();
    let mut scanned_through = after;
    while let Some(row) = rows.next()? {
        let sequence: i64 = row.get(0)?;
        let payload_bytes: i64 = row.get(10)?;
        let visibility_bytes: i64 = row.get(11)?;
        let metadata_bytes: i64 = row.get(12)?;
        // Bound raw replay data before materialization and check encoded size afterward for JSON-escaping expansion.
        let raw_bytes = payload_bytes
            .saturating_add(visibility_bytes)
            .saturating_add(metadata_bytes);
        if raw_bytes > MAX_EVENT_ENVELOPE_BYTES as i64 {
            return Err(ReplayError::EventTooLarge(sequence));
        }
        let visibility_json: String = row.get(8)?;
        let visibility = serde_json::from_str::<Value>(&visibility_json).map_err(|error| {
            rusqlite::Error::FromSqlConversionFailure(
                8,
                rusqlite::types::Type::Text,
                Box::new(error),
            )
        })?;
        let payload_json: String = row.get(9)?;
        let payload = serde_json::from_str::<Value>(&payload_json).map_err(|error| {
            rusqlite::Error::FromSqlConversionFailure(
                9,
                rusqlite::types::Type::Text,
                Box::new(error),
            )
        })?;
        let envelope = EventEnvelope {
            sequence,
            event_id: row.get(1)?,
            occurred_at: row.get(2)?,
            node_id: row.get(3)?,
            cluster_id: row.get(4)?,
            operation_id: row.get(5)?,
            r#type: row.get(6)?,
            severity: row.get(7)?,
            payload,
        };
        scanned_through = sequence;
        let envelope_size = serde_json::to_vec(&envelope)
            .map(|encoded| encoded.len())
            .unwrap_or(usize::MAX);
        if envelope_size > MAX_EVENT_ENVELOPE_BYTES {
            return Err(ReplayError::EventTooLarge(sequence));
        }
        if viewer.can_see_json(&visibility) {
            envelopes.push_back(
                serde_json::to_value(envelope).expect("event envelope must be serializable"),
            );
        }
    }

    Ok(ReplayBatch {
        envelopes,
        scanned_through,
    })
}

pub(super) struct EventStreamState {
    pub(super) replay: VecDeque<Value>,
    pub(super) replay_after: i64,
    pub(super) high_watermark: i64,
    pub(super) database: Arc<parking_lot::Mutex<Connection>>,
    pub(super) receiver: broadcast::Receiver<Value>,
    pub(super) live_after: i64,
    pub(super) heartbeat: tokio::time::Interval,
    pub(super) viewer: Viewer,
}

/// The envelope as clients see it: server-side scoping metadata removed.
pub(super) fn published_envelope(envelope: &Value) -> Value {
    let mut published = envelope.clone();
    if let Some(object) = published.as_object_mut() {
        object.remove(LIVE_VISIBILITY_KEY);
    }
    published
}

pub(super) fn sse_event(envelope: &Value) -> Option<Event> {
    let sequence = envelope["sequence"].as_i64()?;
    if sequence < 1 {
        return None;
    }
    Some(
        Event::default()
            .event(envelope["type"].as_str().unwrap_or(""))
            .data(serde_json::to_string(&published_envelope(envelope)).ok()?)
            .id(sequence.to_string()),
    )
}

/// Join replay to the pre-subscribed receiver and close on broadcast lag so reconnection can recover durable gaps.
pub fn resumed_stream(
    snapshot: ReplaySnapshot,
    receiver: broadcast::Receiver<Value>,
    database: Arc<parking_lot::Mutex<Connection>>,
    viewer: Viewer,
) -> impl Stream<Item = Result<Event, Infallible>> {
    let start = tokio::time::Instant::now() + HEARTBEAT_INTERVAL;
    let state = EventStreamState {
        replay: VecDeque::new(),
        replay_after: snapshot.replay_after,
        high_watermark: snapshot.high_watermark,
        database,
        receiver,
        live_after: snapshot.live_after,
        heartbeat: tokio::time::interval_at(start, HEARTBEAT_INTERVAL),
        viewer,
    };

    futures::stream::unfold(state, |mut state| async move {
        loop {
            if !state.viewer.is_current(&state.database.lock()) {
                return None;
            }
            if let Some(envelope) = state.replay.pop_front() {
                if let Some(event) = sse_event(&envelope) {
                    return Some((Ok(event), state));
                }
                tracing::error!("invalid retained event skipped");
                continue;
            }

            if state.replay_after < state.high_watermark {
                let database = state.database.clone();
                let after = state.replay_after;
                let high_watermark = state.high_watermark;
                let viewer = state.viewer.clone();
                let batch = tokio::task::spawn_blocking(move || {
                    let conn = database.lock();
                    retained_visible_batch(&conn, after, high_watermark, &viewer)
                })
                .await;
                match batch {
                    Ok(Ok(batch)) => {
                        if batch.scanned_through <= state.replay_after {
                            tracing::error!("event replay batch made no progress");
                            return None;
                        }
                        state.replay_after = batch.scanned_through;
                        state.replay = batch.envelopes;
                        continue;
                    }
                    Ok(Err(ReplayError::EventTooLarge(sequence))) => {
                        tracing::error!(sequence, "oversized retained event blocks safe replay");
                        return None;
                    }
                    Ok(Err(error)) => {
                        tracing::error!(?error, "event replay batch failed");
                        return None;
                    }
                    Err(error) => {
                        tracing::error!(%error, "event replay worker failed");
                        return None;
                    }
                }
            }

            tokio::select! {
                _ = state.heartbeat.tick() => {
                    if !state.viewer.is_current(&state.database.lock()) { return None; }
                    return Some((Ok(Event::default().comment("heartbeat")), state));
                }
                received = state.receiver.recv() => {
                    let envelope = match received {
                        Ok(envelope) => envelope,
                        Err(broadcast::error::RecvError::Closed) => return None,
                        Err(broadcast::error::RecvError::Lagged(dropped)) => {
                            tracing::warn!(dropped, "event stream lagged; closing for cursor resume");
                            return None;
                        }
                    };
                    let Some(sequence) = envelope["sequence"].as_i64() else {
                        tracing::error!("live event without a sequence skipped");
                        continue;
                    };
                    if sequence < 1 {
                        tracing::warn!(sequence, "non-durable live event skipped");
                        continue;
                    }
                    if sequence <= state.live_after {
                        continue;
                    }
                    state.live_after = sequence;
                    // Refuse live frames without visibility metadata so incomplete emitters cannot leak events.
                    let Some(rule) = envelope.get(LIVE_VISIBILITY_KEY) else {
                        tracing::error!(sequence, "live event without a visibility rule skipped");
                        continue;
                    };
                    if !state.viewer.is_current(&state.database.lock()) { return None; }
                    if !state.viewer.can_see_json(rule) {
                        continue;
                    }
                    if let Some(event) = sse_event(&envelope) {
                        return Some((Ok(event), state));
                    }
                    tracing::error!(sequence, "invalid live event skipped");
                }
            }
        }
    })
}
