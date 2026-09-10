//! Persist event visibility and enforce it for both durable replay and live delivery.

use std::collections::{HashSet, VecDeque};

use std::convert::Infallible;

use std::sync::Arc;

use std::time::Duration;

use axum::response::sse::Event;

use futures::Stream;

use rusqlite::Connection;

use serde_json::Value;

use tokio::sync::broadcast;

use uuid::Uuid;

use crate::capability::Role;

use crate::clock::{UtcClock, system_clock};

/// Capacity of the live fan-out channel; durable rows carry history.
pub const FANOUT_CAPACITY: usize = 1024;

pub const HEARTBEAT_INTERVAL: Duration = Duration::from_secs(15);

pub const REPLAY_BATCH_SIZE: usize = 16;

pub const MAX_EVENT_ENVELOPE_BYTES: usize = 1_048_576;

/// Bound retained event rows while preserving the replay floor and rejecting expired cursors.
pub const EVENT_RETENTION_ROWS: usize = 10_000;

/// §60.3 gives each event class its own floor so volume in one class cannot evict another.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct EventRetention {
    /// Newest rows always retained for `Last-Event-ID` replay.
    pub replay_minimum_rows: usize,
    /// Hours of history always retained for replay, whichever floor is larger.
    pub replay_minimum_hours: i64,
    /// Security and identity events; the audit chain itself is never pruned.
    pub security_days: i64,
    /// Durable-operation events.
    pub operation_days: i64,
    /// High-volume lifecycle events such as inference and download progress.
    pub lifecycle_days: i64,
}

impl Default for EventRetention {
    fn default() -> Self {
        Self {
            replay_minimum_rows: EVENT_RETENTION_ROWS,
            replay_minimum_hours: 24,
            security_days: 90,
            operation_days: 30,
            lifecycle_days: 7,
        }
    }
}

impl EventRetention {
    /// Classify by type prefix; an unrecognised prefix takes the shortest floor it can safely have.
    pub fn class_days(&self, event_type: &str) -> i64 {
        if event_type.starts_with("security.")
            || event_type.starts_with("device.")
            || event_type.starts_with("pairing.")
        {
            self.security_days
        } else if event_type.starts_with("operation.") {
            self.operation_days
        } else {
            self.lifecycle_days
        }
    }
}

/// Carry visibility internally and strip it before emitting the public event envelope.
const LIVE_VISIBILITY_KEY: &str = "_visibility";

/// Require every specified visibility constraint to hold.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Visibility {
    /// Minimum role a viewer must hold.
    pub min_role: Option<Role>,
    /// The project a viewer must be a member of.
    pub project_id: Option<Uuid>,
    /// The single device the event is addressed to.
    pub device_id: Option<Uuid>,
}

impl Visibility {
    /// Visible to any authenticated principal.
    pub fn public() -> Self {
        Self::default()
    }

    /// Visible only to members of one project.
    pub fn project(project_id: Uuid) -> Self {
        Self {
            project_id: Some(project_id),
            ..Self::default()
        }
    }

    /// Visible only at or above one role (administrator security events).
    pub fn min_role(role: Role) -> Self {
        Self {
            min_role: Some(role),
            ..Self::default()
        }
    }

    /// Visible only to one device grant.
    pub fn device(device_id: Uuid) -> Self {
        Self {
            device_id: Some(device_id),
            ..Self::default()
        }
    }

    pub fn to_json(&self) -> Value {
        let mut map = serde_json::Map::new();
        if let Some(role) = self.min_role {
            map.insert("min_role".into(), Value::String(role.name().to_owned()));
        }
        if let Some(project_id) = self.project_id {
            map.insert("project_id".into(), Value::String(project_id.to_string()));
        }
        if let Some(device_id) = self.device_id {
            map.insert("device_id".into(), Value::String(device_id.to_string()));
        }
        Value::Object(map)
    }

    /// Parse stored rules conservatively; malformed rules cannot widen their audience.
    pub fn from_json(value: &Value) -> Option<Self> {
        let map = value.as_object()?;
        let mut visibility = Visibility::default();
        for (key, entry) in map {
            match key.as_str() {
                "min_role" => {
                    let text = entry.as_str()?;
                    let role = Role::parse(text);
                    // Reject unknown minimum roles because mapping them to lowest authority would widen visibility.
                    if role.name() != text {
                        return None;
                    }
                    visibility.min_role = Some(role);
                }
                "project_id" => {
                    let id = entry.as_str().and_then(|text| Uuid::parse_str(text).ok())?;
                    visibility.project_id = Some(id);
                }
                "device_id" => {
                    let id = entry.as_str().and_then(|text| Uuid::parse_str(text).ok())?;
                    visibility.device_id = Some(id);
                }
                // Reject unknown rule members rather than ignoring constraints this build cannot understand.
                _ => return None,
            }
        }
        Some(visibility)
    }
}

/// The principal an event stream is being rendered for.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Viewer {
    pub device_id: Uuid,
    pub role: Role,
    pub projects: HashSet<Uuid>,
}

impl Viewer {
    pub fn new(device_id: Uuid, role: Role, projects: HashSet<Uuid>) -> Self {
        Self {
            device_id,
            role,
            projects,
        }
    }

    /// Reload grants before each frame and close on revocation, missing identity or storage failure.
    pub fn is_current(&self, conn: &Connection) -> bool {
        let Ok(Some(device)) = crate::store::load_device_by_id(conn, &self.device_id) else {
            return false;
        };
        let Ok(projects) = crate::store::project_ids_for_device(conn, &self.device_id) else {
            return false;
        };
        self.role == Role::parse(&device.role) && self.projects == projects
    }

    pub fn can_see(&self, visibility: &Visibility) -> bool {
        if let Some(min_role) = visibility.min_role
            && self.role < min_role
        {
            return false;
        }
        if let Some(project_id) = visibility.project_id
            && !self.projects.contains(&project_id)
        {
            return false;
        }
        if let Some(device_id) = visibility.device_id
            && self.device_id != device_id
        {
            return false;
        }
        true
    }

    /// Reject unreadable raw visibility rules before delivery.
    fn can_see_json(&self, value: &Value) -> bool {
        match Visibility::from_json(value) {
            Some(visibility) => self.can_see(&visibility),

            None => false,
        }
    }
}

#[derive(Clone)]
pub struct EventBus {
    sender: broadcast::Sender<Value>,
    clock: Arc<dyn UtcClock>,
}

impl Default for EventBus {
    fn default() -> Self {
        let (sender, _) = broadcast::channel(FANOUT_CAPACITY);
        Self {
            sender,
            clock: system_clock(),
        }
    }
}

impl EventBus {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn with_clock(clock: Arc<dyn UtcClock>) -> Self {
        let (sender, _) = broadcast::channel(FANOUT_CAPACITY);
        Self { sender, clock }
    }

    pub fn subscribe(&self) -> broadcast::Receiver<Value> {
        self.sender.subscribe()
    }

    /// Emit an event visible to every authenticated principal.
    pub fn emit(
        &self,
        conn: Option<&Connection>,
        node_id: &str,
        operation_id: Option<Uuid>,
        event_type: &str,
        severity: &str,
        payload: Value,
    ) {
        self.emit_scoped(
            conn,
            node_id,
            operation_id,
            event_type,
            severity,
            payload,
            Visibility::public(),
        );
    }

    /// Persist visibility alongside events so replay enforces the same audience as live delivery.
    #[allow(clippy::too_many_arguments)]
    pub fn emit_scoped(
        &self,
        conn: Option<&Connection>,
        node_id: &str,
        operation_id: Option<Uuid>,
        event_type: &str,
        severity: &str,
        payload: Value,
        visibility: Visibility,
    ) {
        let envelope = EventEnvelope {
            sequence: 0,
            event_id: Uuid::new_v4().to_string(),
            occurred_at: self.clock.now_rfc3339(),
            node_id: node_id.to_owned(),
            cluster_id: None,
            operation_id: operation_id.map(|id| id.to_string()),
            r#type: event_type.to_owned(),
            severity: severity.to_owned(),
            payload,
        };

        let envelope_size = serde_json::to_vec(&envelope)
            .map(|encoded| encoded.len())
            .unwrap_or(usize::MAX);
        let sequence = if envelope_size > MAX_EVENT_ENVELOPE_BYTES {
            tracing::error!(
                envelope_size,
                event_type,
                "oversized event dropped from durable and live streams"
            );
            0
        } else {
            match conn {
                Some(conn) => match persist(conn, &envelope, &visibility) {
                    Ok(Some(sequence)) => sequence,
                    Ok(None) => 0,
                    Err(error) => {
                        tracing::error!(%error, event_type, "event persistence failed; dropping live event");
                        0
                    }
                },
                None => {
                    tracing::warn!(
                        event_type,
                        "non-durable event dropped from resumable stream"
                    );
                    0
                }
            }
        };
        let mut live = envelope;
        live.sequence = sequence;
        let mut frame = serde_json::to_value(live).expect("envelope serializable");
        if let Some(object) = frame.as_object_mut() {
            object.insert(LIVE_VISIBILITY_KEY.to_owned(), visibility.to_json());
        }
        let _ = self.sender.send(frame);
    }

    /// Encode the event ID, type and data as an SSE frame.
    pub fn sse_frame(envelope: &Value) -> Option<String> {
        let seq = envelope["sequence"].as_i64()?;
        if seq < 1 {
            return None;
        }
        let event = envelope["type"].as_str().unwrap_or("");
        let data = serde_json::to_string(&published_envelope(envelope)).ok()?;
        Some(format!("id: {seq}\nevent: {event}\ndata: {data}\n\n"))
    }

    pub fn heartbeat_frame() -> &'static str {
        ": heartbeat\n\n"
    }
}

/// Persisted public event envelope.
#[derive(Debug, Clone, serde::Serialize)]
pub struct EventEnvelope {
    pub sequence: i64,
    pub event_id: String,
    pub occurred_at: String,
    pub node_id: String,
    pub cluster_id: Option<String>,
    pub operation_id: Option<String>,
    pub r#type: String,
    pub severity: String,
    pub payload: Value,
}

fn persist(
    conn: &Connection,
    envelope: &EventEnvelope,
    visibility: &Visibility,
) -> Result<Option<i64>, rusqlite::Error> {
    conn.execute(
        "INSERT INTO events
            (event_id, event_type, severity, occurred_at, node_id, cluster_id,
             operation_id, resource_id, visibility_json, payload_json)
         VALUES (?1, ?2, ?3, ?4, ?5, NULL, ?6, ?7, ?8, ?9)",
        rusqlite::params![
            envelope.event_id,
            envelope.r#type,
            envelope.severity,
            envelope.occurred_at,
            envelope.node_id,
            envelope.operation_id,
            visibility.project_id.map(|id| id.to_string()),
            visibility.to_json().to_string(),
            serde_json::to_string(&envelope.payload).unwrap_or_else(|_| "{}".into()),
        ],
    )?;
    conn.query_row("SELECT last_insert_rowid()", [], |r| r.get(0))
        .map(Some)
}

#[cfg(test)]
#[path = "events/tests.rs"]
mod tests;

mod event_stream;
use event_stream::published_envelope;
pub use event_stream::{ReplayError, ReplaySnapshot, resumed_stream, retained_public_after};
