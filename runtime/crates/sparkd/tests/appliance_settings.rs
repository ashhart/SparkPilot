//! Verify authenticated, presence-gated settings without persisted secrets using deterministic hardware/process boundaries.

const SIGNING_NODE_ID: uuid::Uuid = uuid::Uuid::from_u128(2);

include!("appliance_settings/scenarios/audit_web_search_setup.rs");

use std::sync::Arc;
use std::time::Duration;

use async_trait::async_trait;
use axum::body::to_bytes;
use axum::http::{Method, Request, StatusCode};
use base64::Engine as _;
use p256::ecdsa::signature::Signer as _;
use p256::pkcs8::EncodePublicKey as _;
use parking_lot::Mutex;
use rand::RngCore;
use rusqlite::Connection;
use serde_json::{Value, json};
use spark_core::identity::{FileIdentityStore, IdentityStore};
use spark_privd::backend::FakeBackend;
use spark_telemetry::{HardwareSnapshot, InferenceSnapshot, SystemMonitor, SystemSnapshot};
use sparkd::appliance_api::{
    ApplianceStatusProvider, BluetoothStatus, HostSettingsStatus, PowerProfileMode,
    PowerProfileStatus, SoftwareUpdateStatus, SystemTimeStatus, TravelAccessPointStatus,
    WifiNetwork,
};
use sparkd::auth;
use sparkd::crypto::{base64url_encode, sha256_hex};
use sparkd::privd::PrivilegedClient;
use sparkd::route::router;
use sparkd::state::{AppState, RuntimeConfig};
use tower::ServiceExt;

struct TestClient {
    key: p256::ecdsa::SigningKey,
    presence_key: p256::ecdsa::SigningKey,
    device_id: uuid::Uuid,
}

#[derive(Debug)]
struct FixedAppliance;

#[derive(Debug, Default)]
struct ThreadRecordingMonitor {
    hardware_threads: std::sync::Mutex<Vec<std::thread::ThreadId>>,
}

impl SystemMonitor for ThreadRecordingMonitor {
    fn system(&self) -> SystemSnapshot {
        SystemMonitor::system(&spark_telemetry::FakeSystemMonitor)
    }

    fn inference(&self) -> InferenceSnapshot {
        InferenceSnapshot::default()
    }

    fn hardware(&self) -> HardwareSnapshot {
        self.hardware_threads
            .lock()
            .unwrap()
            .push(std::thread::current().id());
        SystemMonitor::hardware(&spark_telemetry::FakeSystemMonitor)
    }
}

#[async_trait]
impl ApplianceStatusProvider for FixedAppliance {
    async fn host_settings(&self, observed_at: &str) -> HostSettingsStatus {
        HostSettingsStatus {
            direct_ethernet_enabled: true,
            travel_access_point: TravelAccessPointStatus {
                enabled: false,
                ssid: None,
                security: "unavailable".into(),
                auto_revert_seconds: 90,
            },
            bluetooth: BluetoothStatus {
                available: true,
                powered: true,
                discovering: false,
                nearby_devices: Vec::new(),
            },
            power_profile: PowerProfileStatus {
                available: true,
                current_mode_id: Some(1),
                current_name: Some("Balanced".into()),
                modes: vec![PowerProfileMode {
                    mode_id: 1,
                    name: "Balanced".into(),
                }],
                reboot_required: false,
                temperature_celsius: None,
                power_draw_watts: None,
                power_limit_watts: None,
            },
            software_updates: SoftwareUpdateStatus {
                checked_at: observed_at.into(),
                system_packages_available: Some(2),
                firmware_updates_available: Some(0),
                runtime_release_id: None,
                reboot_required: false,
            },
            time: SystemTimeStatus {
                timezone: "Europe/London".into(),
                ntp_enabled: true,
                synchronized: true,
            },
        }
    }

    async fn wifi_networks(&self) -> Vec<WifiNetwork> {
        vec![WifiNetwork {
            ssid: "Main WiFi".into(),
            security: "wpa3".into(),
            signal_percent: 91,
            connected: false,
            saved: false,
        }]
    }

    async fn container_storage(&self) -> (u64, u64) {
        (42, 21)
    }
}

fn signing_key() -> p256::ecdsa::SigningKey {
    loop {
        let mut scalar = [0; 32];
        rand::rng().fill_bytes(&mut scalar);
        if let Ok(key) = p256::ecdsa::SigningKey::from_slice(&scalar) {
            return key;
        }
    }
}

fn test_client() -> TestClient {
    TestClient {
        key: signing_key(),
        presence_key: signing_key(),
        device_id: uuid::Uuid::new_v4(),
    }
}

fn insert_test_client(connection: &Connection, client: &TestClient, role: &str) {
    let signing_spki = client
        .key
        .verifying_key()
        .to_public_key_der()
        .unwrap()
        .as_bytes()
        .to_vec();
    let presence_spki = client
        .presence_key
        .verifying_key()
        .to_public_key_der()
        .unwrap()
        .as_bytes()
        .to_vec();
    sparkd::store::insert_device_with_presence_key(
        connection,
        &client.device_id,
        "test client",
        "ios",
        &signing_spki,
        &sha256_hex(&signing_spki),
        role,
        Some((&presence_spki, &sha256_hex(&presence_spki))),
    )
    .unwrap();
}

fn test_state(role: &str) -> (AppState, TestClient, Arc<std::sync::Mutex<Vec<String>>>) {
    let directory = tempfile::tempdir().unwrap();
    let mut identity = FileIdentityStore::new(directory.path().join("identity"))
        .load_or_create("test-node")
        .unwrap();
    identity.public.node_id = SIGNING_NODE_ID;
    let mut connection = Connection::open_in_memory().unwrap();
    sparkd::migration::migrate(&mut connection).unwrap();
    let client = test_client();
    insert_test_client(&connection, &client, role);
    let database = Arc::new(Mutex::new(connection));
    let config = RuntimeConfig {
        api_major: 1,
        runtime_version: "0.1.0".into(),
        listen: "127.0.0.1:0".parse().unwrap(),
        node_name: "test-node".into(),
        data_dir: directory.keep(),
        advertise: false,
        tls: false,
    };
    let socket = config.data_dir.join("spark-privd.sock");
    let update_staging_root = config.data_dir.join("updates");
    let listener = spark_privd::server::bind_socket(&socket).unwrap();
    let backend = FakeBackend::default();
    let observed = backend.observed_operations.clone();
    let allowed_uid = unsafe { libc::geteuid() };
    std::thread::spawn(move || {
        let _ = spark_privd::server::serve(listener, allowed_uid, &backend);
    });
    let state = AppState::new(
        config,
        identity,
        Arc::new(spark_telemetry::FakeSystemMonitor),
        None,
    )
    .with_database(database)
    .with_privileged_socket(PrivilegedClient::new(socket))
    .with_optional_service_recipe_paths(
        std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../../recipes/open-webui.service.json"),
        std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../../packaging/trust/service-root.pub"),
    )
    .with_optional_services_available(true)
    .with_runtime_update_staging_root(update_staging_root)
    .with_appliance_status_provider(Arc::new(FixedAppliance));
    (state, client, observed)
}

fn signed_request(
    client: &TestClient,
    method: Method,
    path: &str,
    body: Value,
    presence: bool,
) -> Request<axum::body::Body> {
    let bytes = if body.is_null() {
        Vec::new()
    } else {
        serde_json::to_vec(&body).unwrap()
    };
    let mut nonce = [0; 24];
    rand::rng().fill_bytes(&mut nonce);
    let nonce = base64url_encode(&nonce);
    let now = time::OffsetDateTime::now_utc();
    let timestamp = now
        .format(&time::format_description::well_known::Rfc3339)
        .unwrap();
    let content_sha256 = sha256_hex(&bytes);
    let canonical = auth::canonical(
        method.as_str(),
        path,
        &timestamp,
        &nonce,
        &content_sha256,
        &client.device_id,
        &SIGNING_NODE_ID,
    );
    let signature: p256::ecdsa::Signature = client.key.sign(canonical.as_bytes());
    let mut builder = Request::builder()
        .method(method.clone())
        .uri(path)
        .header("content-type", "application/json")
        .header(auth::HEADER_DEVICE_ID, client.device_id.to_string())
        .header("x-spark-node-id", SIGNING_NODE_ID.to_string())
        .header(auth::HEADER_TIMESTAMP, &timestamp)
        .header(auth::HEADER_NONCE, &nonce)
        .header(auth::HEADER_CONTENT_SHA256, &content_sha256)
        .header(
            auth::HEADER_SIGNATURE,
            base64url_encode(&signature.to_bytes()),
        );
    if method != Method::GET {
        builder = builder.header("idempotency-key", uuid::Uuid::new_v4().to_string());
    }
    if presence {
        let expires_at = (now + time::Duration::seconds(45))
            .format(&time::format_description::well_known::Rfc3339)
            .unwrap();
        let canonical = spark_contracts::user_presence_canonical(
            method.as_str(),
            path,
            &timestamp,
            &nonce,
            &content_sha256,
            &client.device_id,
            &expires_at,
            &SIGNING_NODE_ID,
        );
        let signature: p256::ecdsa::Signature = client.presence_key.sign(canonical.as_bytes());
        let proof = spark_contracts::UserPresenceHeader {
            version: spark_contracts::USER_PRESENCE_PROOF_VERSION,
            expires_at,
            signature: base64url_encode(&signature.to_bytes()),
        };
        builder = builder.header(
            sparkd::user_presence::HEADER_USER_PRESENCE,
            base64url_encode(&serde_json::to_vec(&proof).unwrap()),
        );
    }
    builder.body(axum::body::Body::from(bytes)).unwrap()
}

async fn send(state: AppState, request: Request<axum::body::Body>) -> (StatusCode, Value) {
    let response = router(state).oneshot(request).await.unwrap();
    let status = response.status();
    let bytes = to_bytes(response.into_body(), 1 << 20).await.unwrap();
    (
        status,
        serde_json::from_slice(&bytes).unwrap_or(Value::Null),
    )
}

async fn send_gateway(state: AppState, request: Request<axum::body::Body>) -> StatusCode {
    sparkd::service_api::inference_gateway_router(state)
        .oneshot(request)
        .await
        .unwrap()
        .status()
}

fn wait_for(observed: &Arc<std::sync::Mutex<Vec<String>>>, kind: &str) {
    for _ in 0..80 {
        if observed.lock().unwrap().iter().any(|value| value == kind) {
            return;
        }
        std::thread::sleep(Duration::from_millis(25));
    }
    panic!("timed out waiting for {kind}");
}

include!(
    "appliance_settings/scenarios/settings_and_wifi_snapshots_are_typed_and_never_return_credentials.rs"
);

include!(
    "appliance_settings/scenarios/appliance_hardware_probes_leave_the_async_handler_thread.rs"
);

include!(
    "appliance_settings/scenarios/wifi_credentials_reach_only_the_typed_privileged_boundary.rs"
);

include!(
    "appliance_settings/scenarios/network_routes_reject_interface_uuid_profile_path_and_shell_fields.rs"
);

include!(
    "appliance_settings/scenarios/network_mutations_require_administrator_authority_and_fresh_presence.rs"
);

include!(
    "appliance_settings/scenarios/static_ipv4_rejects_an_off_link_gateway_before_privileged_execution.rs"
);

include!(
    "appliance_settings/scenarios/static_ipv4_is_presence_gated_and_creates_a_confirmable_operation.rs"
);

include!(
    "appliance_settings/scenarios/travel_access_point_secret_reaches_only_the_typed_privileged_boundary.rs"
);

include!(
    "appliance_settings/scenarios/weak_travel_access_point_password_is_rejected_before_an_operation_is_created.rs"
);

include!(
    "appliance_settings/scenarios/a_different_paired_device_cannot_confirm_a_network_change.rs"
);

include!(
    "appliance_settings/scenarios/a_different_paired_device_cannot_roll_back_a_network_change.rs"
);

include!("appliance_settings/scenarios/initiating_device_can_confirm_its_network_change.rs");

include!(
    "appliance_settings/scenarios/signed_runtime_bundle_is_staged_without_entering_operation_or_audit_records.rs"
);
include!(
    "appliance_settings/scenarios/a_runtime_update_waits_for_filesystem_mutations_to_finish.rs"
);

include!(
    "appliance_settings/scenarios/update_detection_refreshes_package_and_firmware_metadata_through_privd.rs"
);

include!("appliance_settings/scenarios/update_detection_refresh_requires_fresh_owner_presence.rs");

include!(
    "appliance_settings/scenarios/open_webui_install_is_owner_confirmed_durable_and_secret_free_at_rest.rs"
);

include!("appliance_settings/scenarios/open_webui_install_fails_closed_without_presence.rs");

include!(
    "appliance_settings/scenarios/open_webui_status_recovers_an_install_interrupted_after_container_start.rs"
);

include!(
    "appliance_settings/scenarios/open_webui_status_disables_access_after_an_interrupted_remove.rs"
);

include!(
    "appliance_settings/scenarios/open_webui_install_replay_returns_the_original_operation_without_rotating_credentials.rs"
);

include!(
    "appliance_settings/scenarios/open_webui_update_and_remove_are_durable_owner_confirmed_operations.rs"
);

fn seed_repair_gateway(state: &AppState, client: &TestClient, pending: bool) {
    state.database.as_ref().unwrap().lock().execute(
        "INSERT INTO optional_services
            (service_id, enabled, pending_install, gateway_token_sha256, owner_device_id, recipe_revision, updated_at)
         VALUES ('open-webui', ?1, ?2, ?3, ?4, 'fixture', '2026-09-04T00:00:00Z')",
        rusqlite::params![!pending, pending, "a".repeat(64), client.device_id.to_string()],
    ).unwrap();
}

include!(
    "appliance_settings/scenarios/open_webui_repair_requires_owner_presence_and_existing_gateway.rs"
);

include!(
    "appliance_settings/scenarios/open_webui_repair_is_durable_idempotent_and_recovers_pending_gateway.rs"
);

include!(
    "appliance_settings/scenarios/open_webui_gateway_accepts_only_its_scoped_token_and_has_no_management_routes.rs"
);

include!(
    "appliance_settings/scenarios/open_webui_access_redirect_uses_the_node_identity_and_dedicated_tls_port.rs"
);

include!(
    "appliance_settings/scenarios/open_webui_access_proxy_fails_closed_until_the_service_is_enabled.rs"
);

include!(
    "appliance_settings/scenarios/open_webui_capability_fails_closed_when_either_listener_is_unavailable.rs"
);

include!(
    "appliance_settings/scenarios/open_webui_capability_and_status_fail_closed_without_packaged_trust_material.rs"
);

include!(
    "appliance_settings/scenarios/runtime_bundle_requires_presence_before_any_bytes_are_staged.rs"
);

include!(
    "appliance_settings/scenarios/runtime_bundle_idempotency_replay_does_not_stage_or_install_twice.rs"
);

include!("appliance_settings/scenarios/appliance_mutations_require_role_and_fresh_presence.rs");

include!(
    "appliance_settings/scenarios/memory_and_telemetry_choices_persist_without_cloud_state.rs"
);

include!("appliance_settings/scenarios/storage_cleanup_never_follows_symlinks.rs");

include!(
    "appliance_settings/scenarios/kokoro_lifecycle_requires_presence_and_speech_requires_inference_authority.rs"
);

include!(
    "appliance_settings/scenarios/kokoro_install_replays_one_durable_operation_and_reports_the_approved_release.rs"
);

include!("appliance_settings/scenarios/model_idle_timeout.rs");
