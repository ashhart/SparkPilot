use std::sync::{Arc, Condvar, Mutex, mpsc};
use std::time::{Duration, Instant};

use axum::Json;
use axum::extract::{Extension, Path as RoutePath, State};
use sha2::{Digest, Sha256};
use spark_models::recipe::fixture::RecipeFixture;
use spark_models::{ModelRecipe, RemoteFile};
use spark_telemetry::FakeSystemMonitor;
use sparkd::auth::{AccessAuthentication, Principal};
use sparkd::download::{DownloadCoordinator, FileSource, SourceResolver};
use sparkd::idempotency::IdempotencyRequest;
use sparkd::models::ModelInventory;
use sparkd::state::{AppState, RuntimeConfig};

struct OneFileResolver(RemoteFile);

impl SourceResolver for OneFileResolver {
    fn resolve(&self, _recipe: &ModelRecipe) -> Result<Vec<RemoteFile>, String> {
        Ok(vec![self.0.clone()])
    }
}

struct BlockingSource {
    started: Mutex<Option<mpsc::Sender<()>>>,
    release: Arc<(Mutex<bool>, Condvar)>,
}

impl FileSource for BlockingSource {
    fn fetch(
        &self,
        _recipe: &ModelRecipe,
        _file: &RemoteFile,
        _range: Option<(u64, usize)>,
    ) -> Result<Vec<u8>, String> {
        if let Some(started) = self.started.lock().unwrap().take() {
            started.send(()).unwrap();
        }
        let (released, condition) = &*self.release;
        let mut released = released.lock().unwrap();
        while !*released {
            released = condition.wait(released).unwrap();
        }
        Ok(vec![7])
    }
}

fn release_download(release: &Arc<(Mutex<bool>, Condvar)>) {
    let (released, condition) = &**release;
    *released.lock().unwrap() = true;
    condition.notify_all();
}

fn idempotency(
    device_id: uuid::Uuid,
    method: &str,
    path: String,
    body: &[u8],
) -> IdempotencyRequest {
    IdempotencyRequest {
        device_id,
        method: method.to_owned(),
        path,
        key: uuid::Uuid::new_v4(),
        body_hash: sparkd::crypto::sha256_hex(body),
        request_id: None,
    }
}

fn operation(state: &AppState, operation_id: uuid::Uuid) -> sparkd::store::OperationRow {
    let database = state.database.as_ref().unwrap();
    state
        .jobs
        .get(&database.lock(), operation_id)
        .unwrap()
        .unwrap()
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn paused_fetch_does_not_block_status_writes_or_cancellation() {
    let data_dir = tempfile::tempdir().unwrap();
    let mut connection = rusqlite::Connection::open_in_memory().unwrap();
    sparkd::migration::migrate(&mut connection).unwrap();
    let mut recipe = RecipeFixture::example();
    // Use the recipe's valid minimum reserve because this test isolates lock release, not memory admission.
    recipe.memory.minimum_system_reserve_bytes = 8 * 1024 * 1024 * 1024;
    sparkd::store::upsert_catalogue_model(&connection, &recipe).unwrap();
    let device_id = uuid::Uuid::new_v4();
    sparkd::store::insert_device(
        &connection,
        &device_id,
        "download lock test",
        "macos",
        b"test-spki",
        "test-fingerprint",
        "owner",
    )
    .unwrap();

    let (started_tx, started_rx) = mpsc::channel();
    let release = Arc::new((Mutex::new(false), Condvar::new()));
    let coordinator = DownloadCoordinator {
        resolver: Box::new(OneFileResolver(RemoteFile {
            relative_path: "one-byte.bin".into(),
            size_bytes: 1,
            sha256: hex::encode(Sha256::digest([7])),
        })),
        source: Box::new(BlockingSource {
            started: Mutex::new(Some(started_tx)),
            release: release.clone(),
        }),
    };
    let state = AppState::new(
        RuntimeConfig {
            api_major: 1,
            runtime_version: "download-lock-test".into(),
            listen: "127.0.0.1:0".parse().unwrap(),
            node_name: "download-lock-test".into(),
            data_dir: data_dir.path().to_path_buf(),
            advertise: false,
            tls: false,
        },
        spark_core::identity::NodeIdentity::generate("download-lock-test"),
        Arc::new(FakeSystemMonitor),
        Some(connection),
    )
    .with_models(Arc::new(ModelInventory {
        recipes: vec![recipe.clone()],
        allow_unverified_import: false,
    }))
    .with_download(coordinator)
    // Remove disk reserve in this fixture because the worker reads real disk capacity while preview uses fake telemetry.
    .with_disk_reserve(0);
    let principal = Principal {
        device_id,
        role: "owner".into(),
        access_authentication: AccessAuthentication::DeviceSignature,
        user_presence: None,
    };
    let install_path = format!("/api/v1/models/{}/install", recipe.id());
    let preview_path = format!("{install_path}/preview");
    let preview = sparkd::download_api::preview_install_model(
        State(state.clone()),
        Extension(principal.clone()),
        idempotency(device_id, "POST", preview_path, b"{}"),
        RoutePath(recipe.id().to_owned()),
        Json(sparkd::download_api::InstallModelPreviewBody::default()),
    )
    .await
    .expect("install preview")
    .0;
    assert_eq!(preview["action"], "install");
    assert_eq!(preview["evidence"]["download_bytes"], 1);
    assert_eq!(preview["evidence"]["locally_reusable_bytes"], 0);
    assert_eq!(preview["evidence"]["required_disk_bytes"], 1);
    assert!(preview["evidence"]["disk_free_bytes"].is_u64());
    let request = sparkd::download_api::InstallModelBody {
        accepted_preview_digest: preview["preview_digest"].as_str().map(str::to_owned),
        ..Default::default()
    };
    let request_bytes = serde_json::to_vec(&serde_json::json!({
        "accepted_preview_digest": request.accepted_preview_digest,
    }))
    .unwrap();
    let (_, body) = sparkd::download_api::install_model(
        State(state.clone()),
        Extension(principal.clone()),
        idempotency(device_id, "POST", install_path.clone(), &request_bytes),
        RoutePath(recipe.id().to_owned()),
        Json(request),
    )
    .await
    .expect("install accepted");
    let operation_id = body["id"]
        .as_str()
        .and_then(|value| uuid::Uuid::parse_str(value).ok())
        .expect("operation id");
    // Allow startup slack under debug load; later assertions retain the actual two-second nonblocking bounds.
    started_rx
        .recv_timeout(Duration::from_secs(10))
        .expect("download reached the paused source");

    // Admit the second durable operation while it waits for the process-wide slot held by the paused download.
    let second_preview = sparkd::download_api::preview_install_model(
        State(state.clone()),
        Extension(principal.clone()),
        idempotency(device_id, "POST", format!("{install_path}/preview"), b"{}"),
        RoutePath(recipe.id().to_owned()),
        Json(sparkd::download_api::InstallModelPreviewBody::default()),
    )
    .await
    .expect("second install preview")
    .0;
    let second_request = sparkd::download_api::InstallModelBody {
        accepted_preview_digest: second_preview["preview_digest"].as_str().map(str::to_owned),
        ..Default::default()
    };
    let second_request_bytes = serde_json::to_vec(&serde_json::json!({
        "accepted_preview_digest": second_request.accepted_preview_digest,
    }))
    .unwrap();
    let (_, second_body) = sparkd::download_api::install_model(
        State(state.clone()),
        Extension(principal.clone()),
        idempotency(
            device_id,
            "POST",
            install_path.clone(),
            &second_request_bytes,
        ),
        RoutePath(recipe.id().to_owned()),
        Json(second_request),
    )
    .await
    .expect("second install accepted");
    let second_operation_id = second_body["id"]
        .as_str()
        .and_then(|value| uuid::Uuid::parse_str(value).ok())
        .expect("second operation id");
    let running_deadline = Instant::now() + Duration::from_secs(2);
    while operation(&state, second_operation_id).state != "running" {
        assert!(
            Instant::now() < running_deadline,
            "second operation did not reach the download-slot wait"
        );
        tokio::time::sleep(Duration::from_millis(10)).await;
    }

    let queued_cancel_state = state.clone();
    let queued_cancel = tokio::spawn(async move {
        sparkd::download_api::cancel_operation(
            State(queued_cancel_state),
            Extension(Principal {
                device_id,
                role: "owner".into(),
                access_authentication: AccessAuthentication::DeviceSignature,
                user_presence: None,
            }),
            idempotency(
                device_id,
                "POST",
                format!("/api/v1/operations/{second_operation_id}/cancel"),
                b"",
            ),
            RoutePath(second_operation_id),
        )
        .await
    });

    let status_state = state.clone();
    let status = tokio::spawn(async move {
        sparkd::handlers::status(State(status_state), Extension(principal)).await
    });
    let database = state.database.as_ref().unwrap().clone();
    let write = tokio::task::spawn_blocking(move || {
        database
            .lock()
            .execute_batch("CREATE TEMP TABLE concurrent_write(value INTEGER)")
    });
    let cancel_state = state.clone();
    let cancel = tokio::spawn(async move {
        sparkd::download_api::cancel_operation(
            State(cancel_state),
            Extension(Principal {
                device_id,
                role: "owner".into(),
                access_authentication: AccessAuthentication::DeviceSignature,
                user_presence: None,
            }),
            idempotency(
                device_id,
                "POST",
                format!("/api/v1/operations/{operation_id}/cancel"),
                b"",
            ),
            RoutePath(operation_id),
        )
        .await
    });

    tokio::time::sleep(Duration::from_millis(200)).await;
    let status_ready = status.is_finished();
    let write_ready = write.is_finished();
    let cancel_ready = cancel.is_finished();
    let cancellation_signalled = state.jobs.worker_cancelled(operation_id);
    let cancellation_persisted =
        cancel_ready && operation(&state, operation_id).state == "cancelling";
    let queued_cancellation_terminal = operation(&state, second_operation_id).state == "cancelled";

    release_download(&release);
    let status_result = tokio::time::timeout(Duration::from_secs(2), status)
        .await
        .expect("status completes after fetch release")
        .expect("status task joins");
    let write_result = tokio::time::timeout(Duration::from_secs(2), write)
        .await
        .expect("write completes after fetch release")
        .expect("write task joins");
    let cancel_result = tokio::time::timeout(Duration::from_secs(2), cancel)
        .await
        .expect("cancel completes after fetch release")
        .expect("cancel task joins");
    let queued_cancel_result = tokio::time::timeout(Duration::from_secs(2), queued_cancel)
        .await
        .expect("queued cancel completes after fetch release")
        .expect("queued cancel task joins");

    assert!(
        status_ready
            && write_ready
            && cancel_ready
            && cancellation_signalled
            && cancellation_persisted,
        "status_ready={status_ready} write_ready={write_ready} cancel_ready={cancel_ready} cancellation_signalled={cancellation_signalled} cancellation_persisted={cancellation_persisted}"
    );
    let _ = status_result.expect("status succeeds while fetch is paused");
    write_result.expect("unrelated write succeeds while fetch is paused");
    let (cancel_status, _) = cancel_result.expect("cancel is accepted while fetch is paused");
    assert_eq!(cancel_status, axum::http::StatusCode::ACCEPTED);
    let (queued_cancel_status, _) =
        queued_cancel_result.expect("queued cancellation is accepted while fetch is paused");
    assert_eq!(queued_cancel_status, axum::http::StatusCode::ACCEPTED);
    assert!(
        queued_cancellation_terminal,
        "a cancelled install waiting for the download slot remained parked behind the active download"
    );

    let deadline = Instant::now() + Duration::from_secs(2);
    loop {
        let row = operation(&state, operation_id);
        if matches!(row.state.as_str(), "cancelled" | "failed" | "succeeded") {
            assert_eq!(row.state, "cancelled");
            let error_code: Option<String> = state
                .database
                .as_ref()
                .unwrap()
                .lock()
                .query_row(
                    "SELECT error_code FROM operations WHERE id = ?1",
                    [operation_id.to_string()],
                    |row| row.get(0),
                )
                .unwrap();
            assert_eq!(error_code.as_deref(), Some("OPERATION_CANCELLED"));
            break;
        }
        assert!(
            Instant::now() < deadline,
            "operation did not become terminal"
        );
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    let model = sparkd::store::model_row(&state.database.as_ref().unwrap().lock(), recipe.id())
        .unwrap()
        .unwrap();
    assert_eq!(model.install_state, "available");
    assert!(!data_dir.path().join("models/snapshots").exists());
}
