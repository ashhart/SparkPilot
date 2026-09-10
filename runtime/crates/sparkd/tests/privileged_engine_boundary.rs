//! Prepare the exact pinned image before sending the complete typed Docker launch request.

use axum::Json;
use axum::extract::State;
use axum::http::{HeaderMap, StatusCode, header::AUTHORIZATION};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use serde_json::json;
use spark_models::recipe::fixture::RecipeFixture;
use spark_privd::backend::{FakeBackend, OpBackend};
use spark_privd::protocol::PrivilegedResponse;
use sparkd::engine::{
    EngineBackend, EngineImagePreparation, EngineInstance, derived_internal_port,
};
use sparkd::engine_backend::DockerEngineBackend;
use sparkd::privd::PrivilegedClient;
use std::sync::Arc;
use std::time::{Duration, Instant};

use spark_privd::protocol::PrivilegedOperation;
use uuid::Uuid;

#[derive(Default)]
struct RecordingBackend {
    operations: Arc<std::sync::Mutex<Vec<PrivilegedOperation>>>,
}

impl OpBackend for RecordingBackend {
    fn execute(
        &self,
        operation: &PrivilegedOperation,
    ) -> Result<PrivilegedResponse, spark_privd::backend::BackendError> {
        self.operations.lock().unwrap().push(operation.clone());
        let request_id = operation.request_id();
        Ok(match operation {
            PrivilegedOperation::StartModel { .. } => PrivilegedResponse {
                request_id,
                accepted: true,
                code: "started".into(),
                message: "recorded model start".into(),
                details: json!({}),
            },
            _ => PrivilegedResponse::rejected(
                request_id,
                "unexpected_operation",
                "the boundary test accepts only model starts",
            ),
        })
    }
}

#[tokio::test]
async fn product_adapter_prepares_the_image_before_starting_the_model() {
    let directory = tempfile::tempdir().unwrap();
    let socket = directory.path().join("spark-privd.sock");
    let listener = spark_privd::server::bind_socket(&socket).unwrap();
    let fake = FakeBackend::default();
    let observed = fake.observed_operations.clone();
    let allowed_uid = unsafe { libc::geteuid() };
    std::thread::spawn(move || {
        let _ = spark_privd::server::serve(listener, allowed_uid, &fake);
    });

    let recipe = RecipeFixture::example();
    let profile = recipe.profiles[0].clone();
    let instance_id = Uuid::new_v4();
    let instance = EngineInstance {
        instance_id,
        model_id: recipe.id().to_owned(),
        profile_id: profile.id.clone(),
        served_name: recipe.engine.served_name.clone(),
        model_snapshot: directory
            .path()
            .join("models/snapshots/example/model/revision"),
        internal_port: derived_internal_port(instance_id),
        api_key: "a".repeat(64),
        external_workload_id: None,
        recipe,
        profile,
        memory_baseline_bytes: 100_000_000_000,
        memory_limit_bytes: None,
        gpu_memory_utilisation_milli: 700,
    };
    let backend = DockerEngineBackend::new(PrivilegedClient::new(&socket));

    let preparation = backend.prepare(&instance).await.unwrap();
    let calls_after_preparation = observed.lock().unwrap().clone();
    let port = backend.launch(&instance).await.unwrap();

    assert_eq!(preparation, EngineImagePreparation::AlreadyAvailable);
    assert_eq!(calls_after_preparation, ["ensure_engine_image"]);
    assert_eq!(port, instance.internal_port);
    assert_eq!(
        *observed.lock().unwrap(),
        ["ensure_engine_image", "start_model"]
    );
}

#[tokio::test]
async fn product_adapter_preserves_the_verified_recipe_network_policy() {
    let directory = tempfile::tempdir().unwrap();
    let socket = directory.path().join("spark-privd.sock");
    let listener = spark_privd::server::bind_socket(&socket).unwrap();
    let recorder = RecordingBackend::default();
    let operations = recorder.operations.clone();
    let allowed_uid = unsafe { libc::geteuid() };
    std::thread::spawn(move || {
        let _ = spark_privd::server::serve(listener, allowed_uid, &recorder);
    });
    let backend = DockerEngineBackend::new(PrivilegedClient::new(&socket));

    for allow_network_during_inference in [false, true] {
        let mut recipe = RecipeFixture::example();
        recipe.security.allow_network_during_inference = allow_network_during_inference;
        let profile = recipe.profiles[0].clone();
        let instance_id = Uuid::new_v4();
        let instance = EngineInstance {
            instance_id,
            model_id: recipe.id().to_owned(),
            profile_id: profile.id.clone(),
            served_name: recipe.engine.served_name.clone(),
            model_snapshot: directory
                .path()
                .join("models/snapshots/example/model/revision"),
            internal_port: derived_internal_port(instance_id),
            api_key: "a".repeat(64),
            external_workload_id: None,
            recipe,
            profile,
            memory_baseline_bytes: 100_000_000_000,
            memory_limit_bytes: None,
            gpu_memory_utilisation_milli: 700,
        };

        backend.launch(&instance).await.unwrap();
    }

    let captured = operations.lock().unwrap();
    let policies = captured
        .iter()
        .map(|operation| match operation {
            PrivilegedOperation::StartModel {
                allow_network_during_inference,
                ..
            } => *allow_network_during_inference,
            other => panic!("unexpected privileged operation: {}", other.kind()),
        })
        .collect::<Vec<_>>();
    assert_eq!(policies, [false, true]);
}

/// ADR-043: KV plus recurrent state reaches the helper as an absolute budget; a peak-only recipe sends none.
#[tokio::test]
async fn product_adapter_forwards_the_engine_cache_budget_from_recipe_arithmetic() {
    let directory = tempfile::tempdir().unwrap();
    let socket = directory.path().join("spark-privd.sock");
    let listener = spark_privd::server::bind_socket(&socket).unwrap();
    let recorder = RecordingBackend::default();
    let operations = recorder.operations.clone();
    let allowed_uid = unsafe { libc::geteuid() };
    std::thread::spawn(move || {
        let _ = spark_privd::server::serve(listener, allowed_uid, &recorder);
    });
    let backend = DockerEngineBackend::new(PrivilegedClient::new(&socket));

    let mut arithmetic = RecipeFixture::example();
    arithmetic.memory.expected_weight_bytes = 24_000_000_000;
    arithmetic.memory.kv_cache_bytes_per_token = Some(3072);
    arithmetic.memory.state_bytes_per_sequence = Some(25_165_824);
    arithmetic.profiles[0].max_model_length = 262_144;
    arithmetic.profiles[0].max_sequences = 16;
    arithmetic.profiles[0].expected_peak_bytes = 45_877_489_664;
    for recipe in [RecipeFixture::example(), arithmetic] {
        let profile = recipe.profiles[0].clone();
        let instance_id = Uuid::new_v4();
        let instance = EngineInstance {
            instance_id,
            model_id: recipe.id().to_owned(),
            profile_id: profile.id.clone(),
            served_name: recipe.engine.served_name.clone(),
            model_snapshot: directory
                .path()
                .join("models/snapshots/example/model/revision"),
            internal_port: derived_internal_port(instance_id),
            api_key: "a".repeat(64),
            external_workload_id: None,
            recipe,
            profile,
            memory_baseline_bytes: 100_000_000_000,
            memory_limit_bytes: None,
            gpu_memory_utilisation_milli: 700,
        };
        backend.launch(&instance).await.unwrap();
    }

    let captured = operations.lock().unwrap();
    let budgets = captured
        .iter()
        .map(|operation| match operation {
            PrivilegedOperation::StartModel {
                kv_cache_memory_bytes,
                ..
            } => *kv_cache_memory_bytes,
            other => panic!("unexpected privileged operation: {}", other.kind()),
        })
        .collect::<Vec<_>>();
    assert_eq!(budgets, [None, Some(12_884_901_888 + 402_653_184)]);
}

/// ADR-043: the helper receives the share the load derived, not the profile's declared one.
#[tokio::test]
async fn product_adapter_forwards_the_derived_utilisation_share() {
    let directory = tempfile::tempdir().unwrap();
    let socket = directory.path().join("spark-privd.sock");
    let listener = spark_privd::server::bind_socket(&socket).unwrap();
    let recorder = RecordingBackend::default();
    let operations = recorder.operations.clone();
    let allowed_uid = unsafe { libc::geteuid() };
    std::thread::spawn(move || {
        let _ = spark_privd::server::serve(listener, allowed_uid, &recorder);
    });
    let backend = DockerEngineBackend::new(PrivilegedClient::new(&socket));

    let recipe = RecipeFixture::example();
    let profile = recipe.profiles[0].clone();
    let instance_id = Uuid::new_v4();
    let instance = EngineInstance {
        instance_id,
        model_id: recipe.id().to_owned(),
        profile_id: profile.id.clone(),
        served_name: recipe.engine.served_name.clone(),
        model_snapshot: directory
            .path()
            .join("models/snapshots/example/model/revision"),
        internal_port: derived_internal_port(instance_id),
        api_key: "a".repeat(64),
        external_workload_id: None,
        recipe,
        profile,
        memory_baseline_bytes: 100_000_000_000,
        memory_limit_bytes: None,
        gpu_memory_utilisation_milli: 450,
    };
    backend.launch(&instance).await.unwrap();

    let captured = operations.lock().unwrap();
    let shares = captured
        .iter()
        .map(|operation| match operation {
            PrivilegedOperation::StartModel {
                gpu_memory_utilisation_milli,
                ..
            } => *gpu_memory_utilisation_milli,
            other => panic!("unexpected privileged operation: {}", other.kind()),
        })
        .collect::<Vec<_>>();
    assert_eq!(shares, [450]);
}

fn authenticated(headers: &HeaderMap, key: &str) -> bool {
    headers
        .get(AUTHORIZATION)
        .and_then(|value| value.to_str().ok())
        .is_some_and(|value| value == format!("Bearer {key}"))
}

async fn secured_models(State(key): State<Arc<String>>, headers: HeaderMap) -> Response {
    if !authenticated(&headers, &key) {
        return StatusCode::UNAUTHORIZED.into_response();
    }
    Json(json!({"data": [{"id": "example-32b"}]})).into_response()
}

async fn secured_completion(State(key): State<Arc<String>>, headers: HeaderMap) -> Response {
    if !authenticated(&headers, &key) {
        return StatusCode::UNAUTHORIZED.into_response();
    }
    Json(json!({"choices": [{"message": {"content": "ok"}}]})).into_response()
}

#[tokio::test]
async fn product_readiness_probes_authenticate_to_secured_vllm() {
    let listener = tokio::net::TcpListener::bind((std::net::Ipv4Addr::LOCALHOST, 0))
        .await
        .unwrap();
    let port = listener.local_addr().unwrap().port();
    let key = Arc::new("a".repeat(64));
    let router = axum::Router::new()
        .route("/v1/models", get(secured_models))
        .route("/v1/chat/completions", post(secured_completion))
        .with_state(key.clone());
    let server = tokio::spawn(async move {
        axum::serve(listener, router).await.unwrap();
    });

    let recipe = RecipeFixture::example();
    let profile = recipe.profiles[0].clone();
    let instance = EngineInstance {
        instance_id: Uuid::new_v4(),
        model_id: recipe.id().to_owned(),
        profile_id: profile.id.clone(),
        served_name: recipe.engine.served_name.clone(),
        model_snapshot: std::path::PathBuf::from("/unused"),
        internal_port: port,
        api_key: key.as_ref().clone(),
        external_workload_id: None,
        recipe,
        profile,
        memory_baseline_bytes: 100_000_000_000,
        memory_limit_bytes: None,
        gpu_memory_utilisation_milli: 700,
    };
    let backend = DockerEngineBackend::new(PrivilegedClient::new("/unused"));

    assert_eq!(
        backend.list_model_names(&instance).await.unwrap(),
        ["example-32b"]
    );
    backend.probe_completion(&instance).await.unwrap();
    server.abort();
}

/// Report Docker available only when the privileged runtime probe confirms it.
#[tokio::test]
async fn docker_backend_reports_runtime_available_when_privd_confirms() {
    let directory = tempfile::tempdir().unwrap();
    let socket = directory.path().join("spark-privd.sock");
    let listener = spark_privd::server::bind_socket(&socket).unwrap();
    let fake = FakeBackend::default();
    let allowed_uid = unsafe { libc::geteuid() };
    std::thread::spawn(move || {
        let _ = spark_privd::server::serve(listener, allowed_uid, &fake);
    });

    let backend = DockerEngineBackend::new(PrivilegedClient::new(&socket));
    let report = backend.probe_container_runtime();

    assert_eq!(report.backend_kind, "docker");
    assert!(report.available, "privd reported runtime_available");
    assert!(report.detail.is_none());
}

/// Honor a privileged runtime-unavailable result without inferring availability.
#[tokio::test]
async fn docker_backend_reports_runtime_unavailable_when_privd_refuses() {
    let directory = tempfile::tempdir().unwrap();
    let socket = directory.path().join("spark-privd.sock");
    let listener = spark_privd::server::bind_socket(&socket).unwrap();
    let mut fake = FakeBackend::default();
    fake.runtime_unavailable = true;
    let allowed_uid = unsafe { libc::geteuid() };
    std::thread::spawn(move || {
        let _ = spark_privd::server::serve(listener, allowed_uid, &fake);
    });

    let backend = DockerEngineBackend::new(PrivilegedClient::new(&socket));
    let report = backend.probe_container_runtime();

    assert_eq!(report.backend_kind, "docker");
    assert!(!report.available, "privd refused the runtime probe");
    assert!(
        report.detail.is_some(),
        "unavailability carries a reason: {:?}",
        report.detail
    );
}

/// Report unavailable with a cause when no privileged helper socket exists.
#[tokio::test]
async fn docker_backend_reports_runtime_unavailable_without_privd() {
    let directory = tempfile::tempdir().unwrap();
    let socket = directory.path().join("absent-spark-privd.sock");
    let backend = DockerEngineBackend::new(PrivilegedClient::new(&socket));
    let report = backend.probe_container_runtime();

    assert_eq!(report.backend_kind, "docker");
    assert!(!report.available);
    assert!(
        report
            .detail
            .as_deref()
            .is_some_and(|d| d.contains("probe failed")),
        "unreachable privileged helper is surfaced, got {:?}",
        report.detail
    );
}

/// Bound live capability probes so an accepting but silent helper cannot hang the request.
#[tokio::test]
async fn docker_backend_probe_fails_closed_against_a_stalled_helper() {
    let directory = tempfile::tempdir().unwrap();
    let socket = directory.path().join("stalled-spark-privd.sock");
    let listener = spark_privd::server::bind_socket(&socket).unwrap();
    // Accept exactly one connection and hold it open without answering.
    std::thread::spawn(move || {
        if let Ok(_held) = listener.accept() {
            std::thread::sleep(Duration::from_secs(30));
        }
    });

    let backend = DockerEngineBackend::new(PrivilegedClient::new(&socket));
    let bounded = tokio::time::timeout(Duration::from_secs(5), async {
        backend.probe_container_runtime()
    });
    let report = bounded
        .await
        .expect("probe must not hang against a stalled helper");

    assert_eq!(report.backend_kind, "docker");
    assert!(!report.available);
    assert!(
        report.detail.is_some(),
        "stalled helper surfaces a cause: {:?}",
        report.detail
    );
}

/// Require bounded privileged calls to fail at the deadline when the helper never replies.
#[test]
fn privileged_client_bounded_call_returns_error_against_a_stalled_helper() {
    let directory = tempfile::tempdir().unwrap();
    let socket = directory.path().join("stalled-spark-privd-bounded.sock");
    let listener = spark_privd::server::bind_socket(&socket).unwrap();
    std::thread::spawn(move || {
        if let Ok(_held) = listener.accept() {
            std::thread::sleep(Duration::from_secs(30));
        }
    });

    let client = PrivilegedClient::new(&socket);
    let started = Instant::now();
    let result = client.call_bounded(
        PrivilegedOperation::ProbeContainerRuntime {
            request_id: Uuid::new_v4(),
        },
        Duration::from_millis(200),
    );
    assert!(
        started.elapsed() < Duration::from_secs(5),
        "bounded probe must return promptly"
    );
    assert!(
        result.is_err(),
        "stalled helper must yield an error, got {result:?}"
    );
}

/// Preserve NVIDIA OCI registration evidence through typed transport because --gpus=all and load preview depend on it.
#[tokio::test]
async fn gpu_runtime_evidence_crosses_the_privileged_boundary() {
    for (reported, expected) in [(Some(true), Some(true)), (Some(false), Some(false))] {
        let directory = tempfile::tempdir().unwrap();
        let socket = directory.path().join("spark-privd.sock");
        let listener = spark_privd::server::bind_socket(&socket).unwrap();
        let mut fake = FakeBackend::default();
        fake.gpu_runtime = reported;
        let allowed_uid = unsafe { libc::geteuid() };
        std::thread::spawn(move || {
            let _ = spark_privd::server::serve(listener, allowed_uid, &fake);
        });

        let backend = DockerEngineBackend::new(PrivilegedClient::new(&socket));
        let report = backend.probe_container_runtime();

        assert!(report.available);
        assert_eq!(
            report.gpu_runtime, expected,
            "privd reported {reported:?}; the boundary must carry it unchanged"
        );
    }
}

/// Keep missing OCI runtime evidence Unknown rather than converting it to proven absence and blocking every load.
#[tokio::test]
async fn a_silent_container_runtime_leaves_gpu_evidence_unknown() {
    let directory = tempfile::tempdir().unwrap();
    let socket = directory.path().join("spark-privd.sock");
    let listener = spark_privd::server::bind_socket(&socket).unwrap();
    // Default reports availability but volunteers no GPU evidence.
    let fake = FakeBackend::default();
    let allowed_uid = unsafe { libc::geteuid() };
    std::thread::spawn(move || {
        let _ = spark_privd::server::serve(listener, allowed_uid, &fake);
    });

    let backend = DockerEngineBackend::new(PrivilegedClient::new(&socket));
    let report = backend.probe_container_runtime();

    assert!(report.available);
    assert_eq!(report.gpu_runtime, None);
}

/// Do not infer GPU absence from an unreachable helper on top of runtime unavailability.
#[tokio::test]
async fn an_unreachable_helper_leaves_gpu_evidence_unknown() {
    let directory = tempfile::tempdir().unwrap();
    let socket = directory.path().join("absent.sock");
    let backend = DockerEngineBackend::new(PrivilegedClient::new(&socket));
    let report = backend.probe_container_runtime();

    assert!(!report.available);
    assert_eq!(report.gpu_runtime, None);
}

/// Reject every model start the way the helper's driver preflight does.
struct DriverMismatchBackend;

impl OpBackend for DriverMismatchBackend {
    fn execute(
        &self,
        operation: &PrivilegedOperation,
    ) -> Result<PrivilegedResponse, spark_privd::backend::BackendError> {
        Ok(PrivilegedResponse {
            request_id: operation.request_id(),
            accepted: false,
            code: spark_privd::backend::GPU_DRIVER_MISMATCH.into(),
            message: "the NVIDIA driver on this Spark was updated to 580.173.02, but the running kernel still has driver 580.159.03 loaded; restart the Spark, then launch the model again".into(),
            details: json!({
                "kernel_module_version": "580.159.03",
                "nvml_library_version": "580.173.02",
                "docker_stderr": "nvidia-container-cli: initialization error: nvml error: driver/library version mismatch",
            }),
        })
    }
}

#[tokio::test]
async fn a_typed_helper_rejection_leads_with_its_code_and_keeps_the_evidence() {
    let directory = tempfile::tempdir().unwrap();
    let socket = directory.path().join("spark-privd.sock");
    let listener = spark_privd::server::bind_socket(&socket).unwrap();
    let allowed_uid = unsafe { libc::geteuid() };
    std::thread::spawn(move || {
        let _ = spark_privd::server::serve(listener, allowed_uid, &DriverMismatchBackend);
    });
    let recipe = RecipeFixture::example();
    let profile = recipe.profiles[0].clone();
    let instance_id = Uuid::new_v4();
    let instance = EngineInstance {
        instance_id,
        model_id: recipe.id().to_owned(),
        profile_id: profile.id.clone(),
        served_name: recipe.engine.served_name.clone(),
        model_snapshot: directory
            .path()
            .join("models/snapshots/example/model/revision"),
        internal_port: derived_internal_port(instance_id),
        api_key: "a".repeat(64),
        external_workload_id: None,
        recipe,
        profile,
        memory_baseline_bytes: 100_000_000_000,
        memory_limit_bytes: None,
        gpu_memory_utilisation_milli: 700,
    };
    let backend = DockerEngineBackend::new(PrivilegedClient::new(&socket));

    let error = backend
        .launch(&instance)
        .await
        .expect_err("a driver mismatch rejection fails the launch")
        .to_string();

    assert!(
        error.starts_with("GPU_DRIVER_MISMATCH: the NVIDIA driver on this Spark was updated"),
        "{error}"
    );
    assert!(
        error.contains("\"kernel_module_version\":\"580.159.03\""),
        "{error}"
    );
    assert!(error.contains("nvidia-container-cli"), "{error}");
    assert!(!error.contains("privileged launch rejected"), "{error}");
}
