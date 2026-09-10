//! Exercise pressure actions/events, unsafe profiles, migrated usage aggregation and the four-value API pressure projection.

const SIGNING_NODE_ID: uuid::Uuid = uuid::Uuid::from_u128(2);

use std::sync::Arc;
use std::sync::Mutex as StdMutex;
use std::sync::atomic::AtomicBool;
use std::time::Duration;

use axum::body::to_bytes;
use axum::http::{Method, Request, StatusCode};
use axum::response::{IntoResponse, Sse};
use futures::StreamExt as _;
use p256::ecdsa::signature::Signer as _;
use p256::pkcs8::EncodePublicKey;
use parking_lot::Mutex;
use rand::RngCore;
use rusqlite::Connection;
use serde_json::Value;
use spark_core::identity::{FileIdentityStore, IdentityStore};
use spark_telemetry::{MemoryPolicy, MemorySignals, MemorySource};
use sparkd::auth;
use sparkd::crypto::{base64url_encode, sha256_hex};
use sparkd::events::EventBus;
use sparkd::guard::{self, ActiveProfile, EngineControl, MemoryGuardService, NoEngine};

/// Model a serving resident engine so emergency stop has an actual target.
struct RunningEngine;

impl EngineControl for RunningEngine {
    fn drain(&self) -> Result<(), String> {
        Ok(())
    }

    fn graceful_unload(&self) -> Result<(), String> {
        Ok(())
    }

    fn emergency_stop(&self) -> Result<(), String> {
        Ok(())
    }

    fn engine_active(&self) -> bool {
        true
    }
}
use sparkd::route::router;
use sparkd::state::{AppState, RuntimeConfig};
use tower::ServiceExt;

const GIB: u64 = 1024 * 1024 * 1024;

/// Scripted memory source: tests queue the samples the guard will read.
struct ScriptedSource {
    samples: StdMutex<std::collections::VecDeque<MemorySignals>>,
}

impl ScriptedSource {
    fn new(samples: Vec<MemorySignals>) -> Self {
        Self {
            samples: StdMutex::new(samples.into()),
        }
    }

    fn queue(&self, signals: MemorySignals) {
        self.samples.lock().unwrap().push_back(signals);
    }
}

impl MemorySource for ScriptedSource {
    fn signals(&self) -> MemorySignals {
        self.samples
            .lock()
            .unwrap()
            .pop_front()
            .unwrap_or_else(|| MemorySignals::calm(128 * GIB))
    }
}

/// Engine double recording the guard's demands in order.
#[derive(Default)]
struct RecordingEngine {
    actions: StdMutex<Vec<&'static str>>,
    active: StdMutex<bool>,
}

impl EngineControl for RecordingEngine {
    fn resume(&self) -> Result<(), String> {
        self.actions.lock().unwrap().push("resume");
        Ok(())
    }

    fn drain(&self) -> Result<(), String> {
        self.actions.lock().unwrap().push("drain");
        Ok(())
    }

    fn graceful_unload(&self) -> Result<(), String> {
        self.actions.lock().unwrap().push("graceful_unload");
        *self.active.lock().unwrap() = false;
        Ok(())
    }

    fn emergency_stop(&self) -> Result<(), String> {
        self.actions.lock().unwrap().push("emergency_stop");
        *self.active.lock().unwrap() = false;
        Ok(())
    }

    fn engine_active(&self) -> bool {
        *self.active.lock().unwrap()
    }
}

/// Refuse configured initial stop attempts as NotReady during transition, then accept the retry.
struct TransitioningEngine {
    refuse: StdMutex<u32>,
    stops: StdMutex<u32>,
    active: StdMutex<bool>,
}

impl TransitioningEngine {
    fn new(refuse: u32) -> Self {
        Self {
            refuse: StdMutex::new(refuse),
            stops: StdMutex::new(0),
            active: StdMutex::new(true),
        }
    }

    fn stop_count(&self) -> u32 {
        *self.stops.lock().unwrap()
    }
}

impl EngineControl for TransitioningEngine {
    fn drain(&self) -> Result<(), String> {
        Ok(())
    }

    fn graceful_unload(&self) -> Result<(), String> {
        Ok(())
    }

    fn emergency_stop(&self) -> Result<(), String> {
        let mut refuse = self.refuse.lock().unwrap();
        if *refuse > 0 {
            *refuse -= 1;
            return Err("engine is transitioning".into());
        }
        *self.stops.lock().unwrap() += 1;
        *self.active.lock().unwrap() = false;
        Ok(())
    }

    fn engine_active(&self) -> bool {
        *self.active.lock().unwrap()
    }
}

fn sample(available_gib: u64) -> MemorySignals {
    MemorySignals::calm(128 * GIB).with_available(available_gib * GIB)
}

fn migrated_db() -> Connection {
    let mut conn = Connection::open_in_memory().unwrap();
    sparkd::migration::migrate(&mut conn).expect("migrations apply");
    conn
}

fn guard_with(
    source: Arc<ScriptedSource>,
    engine: Arc<RecordingEngine>,
    conn: Option<Arc<Mutex<Connection>>>,
) -> (
    Arc<MemoryGuardService>,
    tokio::sync::broadcast::Receiver<Value>,
) {
    let events = EventBus::new();
    let rx = events.subscribe();
    let engine = engine as Arc<dyn EngineControl>;
    let guard = match conn {
        Some(database) => MemoryGuardService::with_database(
            MemoryPolicy::default(),
            source,
            engine,
            events,
            database,
        ),
        None => MemoryGuardService::without_database_for_testing(
            MemoryPolicy::default(),
            source,
            engine,
            events,
        ),
    };
    let guard = Arc::new(guard.with_technical_diagnostics(Arc::new(AtomicBool::new(true))));
    (guard, rx)
}

fn collect_events(rx: &mut tokio::sync::broadcast::Receiver<Value>) -> Vec<Value> {
    let mut received = Vec::new();
    while let Ok(event) = rx.try_recv() {
        received.push(event);
    }
    received
}

fn event_types(events: &[Value]) -> Vec<&str> {
    events.iter().map(|e| e["type"].as_str().unwrap()).collect()
}

include!(
    "telemetry_guard/scenarios/synthetic_decline_walks_the_ladder_and_drives_engine_actions_in_order.rs"
);

include!(
    "telemetry_guard/scenarios/pressure_transition_receives_a_durable_sequence_and_replays.rs"
);

include!(
    "telemetry_guard/scenarios/emergency_marks_the_active_profile_unsafe_and_blocks_readmission.rs"
);

include!(
    "telemetry_guard/scenarios/an_emergency_stop_that_clears_the_engine_first_still_marks_the_profile.rs"
);

include!("telemetry_guard/scenarios/measured_peaks_and_retry_budget_are_tracked.rs");

include!(
    "telemetry_guard/scenarios/a_peak_measured_under_another_engine_is_not_admission_evidence.rs"
);

include!("telemetry_guard/scenarios/an_unsafe_profile_can_be_explicitly_re_enabled.rs");

include!("telemetry_guard/scenarios/re_enabling_a_safe_profile_is_a_no_op.rs");

fn seed_profile_row(conn: &Connection) {
    conn.execute(
        "INSERT INTO models
            (id, recipe_revision, recipe_digest, source_revision, display_name, install_state)
         VALUES ('llama-8b', 'r1', 'abc123', 'v1', 'Llama 8B', 'installed')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO model_profiles
            (model_id, profile_id, context_length, max_sequences, max_batched_tokens,
             gpu_memory_utilisation, expected_peak_bytes)
         VALUES ('llama-8b', 'balanced-16k', 16384, 8, 8192, 0.9, 0)",
        [],
    )
    .unwrap();
}

include!("telemetry_guard/scenarios/usage_aggregates_into_daily_rows_on_the_migrated_schema.rs");

struct TestClient {
    key: p256::ecdsa::SigningKey,
    device_id: uuid::Uuid,
}

fn signed_get(client: &TestClient, path: &str) -> Request<axum::body::Body> {
    let mut nonce = [0u8; 24];
    rand::rng().fill_bytes(&mut nonce);
    let timestamp = time::OffsetDateTime::now_utc()
        .format(&time::format_description::well_known::Rfc3339)
        .unwrap();
    let canonical = auth::canonical(
        "GET",
        path,
        &timestamp,
        &base64url_encode(&nonce),
        &sha256_hex(b""),
        &client.device_id,
        &SIGNING_NODE_ID,
    );
    let signature: p256::ecdsa::Signature = client.key.sign(canonical.as_bytes());
    Request::builder()
        .method(Method::GET)
        .uri(path)
        .header(auth::HEADER_DEVICE_ID, client.device_id.to_string())
        .header("x-spark-node-id", SIGNING_NODE_ID.to_string())
        .header(auth::HEADER_TIMESTAMP, timestamp)
        .header(auth::HEADER_NONCE, base64url_encode(&nonce))
        .header(auth::HEADER_CONTENT_SHA256, sha256_hex(b""))
        .header(
            auth::HEADER_SIGNATURE,
            base64url_encode(&signature.to_bytes()),
        )
        .body(axum::body::Body::empty())
        .unwrap()
}

include!(
    "telemetry_guard/scenarios/status_and_telemetry_report_the_guard_pressure_for_every_internal_state.rs"
);

include!(
    "telemetry_guard/scenarios/sustained_heat_drains_then_unloads_without_claiming_memory_pressure.rs"
);

include!(
    "telemetry_guard/scenarios/a_node_that_cannot_measure_its_temperature_is_never_acted_on.rs"
);

include!("telemetry_guard/scenarios/a_stop_refused_during_a_load_is_retried_until_it_takes.rs");
