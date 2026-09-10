//! Verify server shapes, secret-free health, real TLS handshakes and signed authentication on protected routes.

const SIGNING_NODE_ID: uuid::Uuid = uuid::Uuid::from_u128(2);

use std::sync::Arc;
use std::time::Duration;

use axum::body::{BodyDataStream, to_bytes};
use axum::http::{HeaderValue, Method, Request, StatusCode};
use futures::StreamExt as _;
use p256::ecdsa::signature::Signer as _;
use p256::pkcs8::EncodePublicKey;
use rand::RngCore;
use serde_json::{Value, json};
use spark_core::identity::{FileIdentityStore, IdentityStore};
use spark_telemetry::{FakeSystemMonitor, InferenceSnapshot, SystemMonitor, SystemSnapshot};
use sparkd::auth;
use sparkd::crypto::{base64url_encode, sha256_hex};
use sparkd::network_api::{
    InternetReachability, NetworkAddress, NetworkInterfaceStatus, NetworkStatusError,
    NetworkStatusProvider,
};
use sparkd::remote::{PrivateOverlayProbe, PrivateOverlayRoute, RemoteAccessService};
use sparkd::route::{router, socket_service};
use sparkd::state::{AppState, RuntimeConfig};
use tower::ServiceExt;

struct TestClient {
    key: p256::ecdsa::SigningKey,
    device_id: uuid::Uuid,
}

struct StaticNetworkStatus;

#[async_trait::async_trait]
impl NetworkStatusProvider for StaticNetworkStatus {
    async fn interfaces(
        &self,
        checked_at: &str,
    ) -> Result<Vec<NetworkInterfaceStatus>, NetworkStatusError> {
        Ok(vec![NetworkInterfaceStatus {
            name: "enp1s0".to_owned(),
            interface_type: "ethernet".to_owned(),
            state: "connected".to_owned(),
            connection_name: Some("Main LAN".to_owned()),
            mac_address: Some("02:00:00:00:00:42".to_owned()),
            mtu: Some(1500),
            link_speed_mbps: Some(10_000),
            addresses: vec![NetworkAddress {
                family: "ipv4".to_owned(),
                address: "192.168.100.63/24".to_owned(),
            }],
            gateway: Some("192.168.100.1".to_owned()),
            dns_servers: vec!["192.168.100.1".to_owned()],
            wifi_ssid: None,
            wifi_signal_percent: None,
            internet: InternetReachability {
                reachable: true,
                gateway_reachable: Some(true),
                dns_reachable: Some(true),
                checked_at: checked_at.to_owned(),
            },
        }])
    }
}

fn fresh_device_key() -> p256::ecdsa::SigningKey {
    loop {
        let mut scalar = [0u8; 32];
        rand::rng().fill_bytes(&mut scalar);
        if let Ok(key) = p256::ecdsa::SigningKey::from_slice(&scalar) {
            return key;
        }
    }
}

fn test_state() -> (AppState, TestClient) {
    let dir = tempfile::tempdir().unwrap();
    let mut identity = FileIdentityStore::new(dir.path().join("identity"))
        .load_or_create("test-node")
        .expect("identity");
    identity.public.node_id = SIGNING_NODE_ID;

    let mut conn = rusqlite::Connection::open_in_memory().expect("db");
    sparkd::migration::migrate(&mut conn).expect("migrate");

    let client = TestClient {
        key: fresh_device_key(),
        device_id: uuid::Uuid::new_v4(),
    };
    let spki = client
        .key
        .verifying_key()
        .to_public_key_der()
        .unwrap()
        .as_bytes()
        .to_vec();
    sparkd::store::insert_device(
        &conn,
        &client.device_id,
        "test client",
        "macos",
        &spki,
        &sparkd::crypto::sha256_hex(&spki),
        "owner",
    )
    .expect("seed owner device");

    let config = RuntimeConfig {
        api_major: 1,
        runtime_version: "0.1.0".to_owned(),
        listen: "127.0.0.1:0".parse().unwrap(),
        node_name: "test-node".to_owned(),
        data_dir: dir.path().to_path_buf(),
        advertise: false,
        tls: false,
    };
    let state = AppState::new(config, identity, Arc::new(FakeSystemMonitor), Some(conn));

    (state, client)
}

fn signed_get(client: &TestClient, path: &str) -> Request<axum::body::Body> {
    let mut nonce = [0u8; 24];
    rand::rng().fill_bytes(&mut nonce);
    let timestamp = time::OffsetDateTime::now_utc()
        .format(&time::format_description::well_known::Rfc3339)
        .expect("rfc3339");
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

fn signed_events_get(client: &TestClient, cursor: Option<&str>) -> Request<axum::body::Body> {
    let mut request = signed_get(client, "/api/v1/events");
    if let Some(cursor) = cursor {
        request.headers_mut().insert(
            "last-event-id",
            HeaderValue::from_str(cursor).expect("valid test header"),
        );
    }
    request
}

async fn open_events(
    state: AppState,
    client: &TestClient,
    cursor: Option<&str>,
) -> axum::response::Response {
    router(state)
        .oneshot(signed_events_get(client, cursor))
        .await
        .unwrap()
}

async fn next_sse_event(stream: &mut BodyDataStream) -> Value {
    let bytes = tokio::time::timeout(Duration::from_secs(1), stream.next())
        .await
        .expect("SSE event timeout")
        .expect("SSE stream ended")
        .expect("SSE body error");
    let frame = String::from_utf8(bytes.to_vec()).expect("SSE is UTF-8");
    let data = frame
        .lines()
        .find_map(|line| line.strip_prefix("data: "))
        .unwrap_or_else(|| panic!("SSE data line missing from {frame:?}"));
    serde_json::from_str(data).expect("SSE data is an event envelope")
}

fn emit_public_event(state: &AppState, event_type: &str) -> i64 {
    let database = state.database.as_ref().expect("event database");
    let conn = database.lock();
    state.events.emit(
        Some(&conn),
        &state.identity.node_id().to_string(),
        Some(uuid::Uuid::new_v4()),
        event_type,
        "info",
        json!({ "source": "signed-http-test" }),
    );
    conn.query_row("SELECT MAX(sequence) FROM events", [], |row| row.get(0))
        .expect("latest sequence")
}

async fn response_json(response: axum::response::Response) -> Value {
    let bytes = to_bytes(response.into_body(), 1 << 20).await.unwrap();
    serde_json::from_slice(&bytes).expect("JSON response")
}

async fn get_json(state: AppState, client: &TestClient, path: &str) -> (StatusCode, Value) {
    let response = router(state)
        .oneshot(signed_get(client, path))
        .await
        .unwrap();
    let status = response.status();
    let bytes = to_bytes(response.into_body(), 1 << 20).await.unwrap();
    let value: Value = serde_json::from_slice(&bytes).unwrap();
    (status, value)
}

include!("server/scenarios/health_matches_contract_and_leaks_no_secret.rs");

include!("server/scenarios/protected_endpoints_require_signature.rs");

include!("server/scenarios/error_envelope_request_id_matches_the_response_header.rs");

include!("server/scenarios/identity_returns_full_record_for_paired_device.rs");

include!("server/scenarios/identity_reports_the_tls_pin_only_when_serving_tls.rs");

include!("server/scenarios/identity_keeps_tls_leaf_pin_distinct_from_pairing_authority.rs");

include!("server/scenarios/status_matches_spec_shape.rs");

include!("server/scenarios/operation_response_keeps_terminal_evidence_from_the_contract.rs");

include!("server/scenarios/telemetry_is_signed_and_returns_the_live_hardware_shape.rs");

include!("server/scenarios/network_interfaces_are_signed_and_return_per_interface_reachability.rs");

include!("server/scenarios/status_reports_real_operation_counts_and_local_transport.rs");

include!("server/scenarios/status_reports_the_remote_service_mode_instead_of_disabled.rs");

struct ReachableTestOverlay;

impl PrivateOverlayProbe for ReachableTestOverlay {
    fn route(&self) -> Result<Option<PrivateOverlayRoute>, String> {
        Ok(Some(PrivateOverlayRoute {
            provider: "tailscale".to_owned(),
            hostname: "100.64.0.9".to_owned(),
            address: Some("100.64.0.9".to_owned()),
        }))
    }
}

struct TelemetryInferenceMonitor;

impl SystemMonitor for TelemetryInferenceMonitor {
    fn system(&self) -> SystemSnapshot {
        FakeSystemMonitor.system()
    }

    fn inference(&self) -> InferenceSnapshot {
        InferenceSnapshot {
            state: "ready".to_owned(),
            model_id: Some("telemetry/fallback".to_owned()),
            profile_id: Some("fallback-profile".to_owned()),
            context_length: Some(4096),
            active_requests: 2,
            queue_depth: Some(3),
            tokens_per_second: Some(12.5),
            time_to_first_token_ms: Some(42.0),
        }
    }
}

include!("server/scenarios/status_uses_telemetry_inference_only_without_an_engine_manager.rs");

include!("server/scenarios/events_replay_retained_public_rows_in_sequence_order.rs");

include!("server/scenarios/events_replay_crosses_fixed_batches_without_skipping.rs");

include!("server/scenarios/events_signed_live_handoff_delivers_each_event_once.rs");

include!("server/scenarios/events_reject_expired_invalid_and_future_cursors.rs");

include!("server/scenarios/sequence_zero_is_skipped_without_closing_a_healthy_stream.rs");

include!("server/scenarios/broadcast_lag_terminates_the_stream_for_cursor_resume.rs");

include!("server/scenarios/event_heartbeat_interval_is_fifteen_seconds.rs");

include!("server/scenarios/tls_server_serves_health.rs");

include!("server/scenarios/production_socket_service_attaches_the_transport_peer.rs");

// PLAN §34 telemetry history: recorded by the runtime, bounded, consent-gated.

include!("server/scenarios/telemetry_history_is_signed_and_separates_raw_from_aggregate.rs");

include!("server/scenarios/telemetry_history_refuses_a_range_or_limit_it_cannot_honour.rs");

include!(
    "server/scenarios/telemetry_history_says_it_is_not_recording_rather_than_showing_an_empty_day.rs"
);

include!("server/scenarios/telemetry_history_carries_no_prompt_response_or_address.rs");
