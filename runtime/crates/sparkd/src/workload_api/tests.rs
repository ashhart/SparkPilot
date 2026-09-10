use super::classification::repository_path;
use super::external_inference::guard_from_observation;
use super::*;
use spark_privd::workloads::ObservedPort;

const MANAGED_ENGINE_ID: &str = "2b0b0d1e-2b3f-4f7b-9b7a-1c1a4a4a9e11";
const MANAGED_WORKTREE_ID: &str = "6f3a1c22-9d4e-4d0a-8b71-0c5f2e7a44d0";

/// Seed durable ownership records rather than inferring authority from host names.
fn recorded() -> ManagedIds {
    ManagedIds {
        engines: [uuid::Uuid::parse_str(MANAGED_ENGINE_ID).unwrap()]
            .into_iter()
            .collect(),
        worktrees: [uuid::Uuid::parse_str(MANAGED_WORKTREE_ID).unwrap()]
            .into_iter()
            .collect(),
        adopted_containers: Default::default(),
    }
}

fn container(name: Option<&str>, image: Option<&str>) -> ObservedContainer {
    ObservedContainer {
        id: "9f2c".into(),
        name: name.map(str::to_owned),
        state: "running".into(),
        image: image.map(str::to_owned),
        ports: Vec::new(),
    }
}

#[test]
fn a_container_this_runtime_has_a_record_of_is_spark_managed() {
    let engine = container(
        Some(&format!("spark-model-{MANAGED_ENGINE_ID}")),
        Some("vllm/vllm-openai@sha256:aa"),
    );
    let classification = classify(&engine, &recorded());
    assert_eq!(classification.ownership, "spark_managed");
    assert_eq!(classification.kind, "inference_engine");
    // The engine word comes from what is running, not from the name.
    assert_eq!(classification.engine, "vllm");

    let project = container(
        Some(&format!("spark-project-{MANAGED_WORKTREE_ID}")),
        Some("debian:bookworm"),
    );
    assert_eq!(classify(&project, &recorded()).ownership, "spark_managed");
    assert_eq!(classify(&project, &recorded()).kind, "project_container");

    // The fixed optional-service name uses its dedicated managed-service classification rule.
    let service = container(Some("spark-open-webui"), Some("ghcr.io/x/y:1"));
    assert_eq!(classify(&service, &recorded()).ownership, "spark_managed");
    assert_eq!(classify(&service, &recorded()).kind, "optional_service");
}

#[test]
fn a_container_this_runtime_never_started_cannot_claim_to_be_managed() {
    // A valid generated-looking container name must not establish ownership without its durable record.
    let impostor = container(
        Some("spark-model-3f0e0b6a-7d3a-4c2a-9b6e-1a2b3c4d5e6f"),
        Some("nginx:latest"),
    );
    let classification = classify(&impostor, &recorded());
    assert_eq!(classification.ownership, "unknown_external");
    assert_eq!(classification.kind, "unknown");

    let project_impostor = container(
        Some("spark-project-3f0e0b6a-7d3a-4c2a-9b6e-1a2b3c4d5e6f"),
        Some("nginx:latest"),
    );
    assert_eq!(
        classify(&project_impostor, &recorded()).ownership,
        "unknown_external"
    );
}

#[test]
fn without_a_record_nothing_is_reported_as_managed() {
    // Failed ownership lookup must leave workloads external and outside lifecycle authority.
    let engine = container(
        Some(&format!("spark-model-{MANAGED_ENGINE_ID}")),
        Some("vllm/vllm-openai@sha256:aa"),
    );
    let classification = classify(&engine, &ManagedIds::default());
    assert_eq!(classification.ownership, "external_observed");
    assert_eq!(classification.engine, "vllm");
}

#[test]
fn an_adopted_container_is_managed_by_exact_container_id_not_its_name() {
    let mut managed = recorded();
    managed.adopted_containers.insert("9f2c".into());
    let adopted = container(
        Some("unrelated-external-name"),
        Some("vllm/vllm-openai@sha256:aa"),
    );
    let classification = classify(&adopted, &managed);
    assert_eq!(classification.ownership, "spark_managed");
    assert_eq!(classification.kind, "inference_engine");
    assert_eq!(classification.engine, "vllm");

    let impostor = ObservedContainer {
        id: "9f2d".into(),
        ..adopted
    };
    assert_eq!(classify(&impostor, &managed).ownership, "external_observed");
}

#[test]
fn a_name_that_only_looks_managed_is_not_claimed() {
    for name in [
        "spark-model-not-a-uuid",
        "spark-model-",
        "spark-project-latest",
        "spark-open-webui-copy",
    ] {
        let observed = container(Some(name), Some("private/image:1"));
        assert_ne!(
            classify(&observed, &recorded()).ownership,
            "spark_managed",
            "{name} must not be claimed as managed"
        );
    }
}

#[test]
fn a_recognised_external_engine_is_observed_not_managed() {
    for (image, engine, kind) in [
        ("vllm/vllm-openai:v0.11.0", "vllm", "inference_engine"),
        ("lmsysorg/sglang:latest", "sglang", "inference_engine"),
        ("rayproject/ray:2.9.0", "ray", "cluster_runtime"),
        (
            "ghcr.io/open-webui/open-webui:main",
            "open_webui",
            "optional_service",
        ),
        // A registry port is not a tag, so the path is still read.
        ("registry.local:5000/vllm:v1", "vllm", "inference_engine"),
    ] {
        let observed = container(Some("deepseek-serve"), Some(image));
        let classification = classify(&observed, &recorded());
        assert_eq!(classification.ownership, "external_observed", "{image}");
        assert_eq!(classification.engine, engine, "{image}");
        assert_eq!(classification.kind, kind, "{image}");
    }
}

#[test]
fn recognition_matches_whole_path_segments_only() {
    // Reject engine labels inferred from substrings or image tags instead of whole repository segments.
    for image in [
        "acme/xray-proxy:1",
        "acme/myvllm-shim:1",
        "acme/sglang-notes:1",
        "acme/betrayal:1",
        "acme/base:ray",
        "internal/notebook:vllm",
        "acme/base@sha256:0123456789abcdef",
    ] {
        let observed = container(Some("service"), Some(image));
        assert_eq!(
            classify(&observed, &recorded()).ownership,
            "unknown_external",
            "{image} must not be recognised"
        );
        assert_eq!(classify(&observed, &recorded()).engine, "none", "{image}");
    }
}

#[test]
fn an_unreadable_workload_is_unknown_external_not_dropped() {
    // Include unidentifiable containers because missing names/images do not remove their resource usage.
    let observed = container(None, None);
    let classification = classify(&observed, &recorded());
    assert_eq!(classification.ownership, "unknown_external");
    assert_eq!(classification.kind, "unknown");
    let presented = present(
        &observed,
        classify(&observed, &recorded()),
        ExternalConfiguration::not_applicable(),
    );
    assert_eq!(presented["name"], Value::Null);
    assert_eq!(presented["image_reference"], Value::Null);
    assert_eq!(presented["workload_id"], "9f2c");
}

#[test]
fn inventory_never_guesses_adoption_eligibility() {
    // Inventory recognition stays advisory; adoption eligibility requires the separate exact signed-recipe review.
    for image in [
        Some("vllm/vllm-openai:v0.11.0"),
        Some("private/image:1"),
        None,
    ] {
        let observed = container(Some("service"), image);
        assert_ne!(
            classify(&observed, &recorded()).ownership,
            "adoption_available"
        );
    }
    const { assert!(ADOPTION_SUPPORTED) };
}

#[test]
fn an_unobservable_host_is_not_reported_as_an_empty_one() {
    let body = unavailable(
        "2026-08-30T09:00:00Z",
        "the container runtime could not be inspected",
        false,
    );
    assert_eq!(body["available"], false);
    assert_eq!(body["workloads"].as_array().map(Vec::len), Some(0));
    assert!(body["unavailable_reason"].is_string());
}

#[test]
fn published_ports_survive_presentation() {
    let mut observed = container(Some("deepseek-serve"), Some("lmsysorg/sglang:latest"));
    observed.ports.push(ObservedPort {
        host_ip: "0.0.0.0".into(),
        host_port: 30000,
        container_port: 30000,
        protocol: "tcp".into(),
    });
    let presented = present(
        &observed,
        classify(&observed, &recorded()),
        ExternalConfiguration::not_applicable(),
    );
    assert_eq!(presented["published_ports"][0]["host_port"], 30000);
    assert_eq!(presented["published_ports"][0]["protocol"], "tcp");
}

#[test]
fn a_repository_path_drops_its_tag_and_digest_but_keeps_a_registry_port() {
    assert_eq!(repository_path("acme/base:ray"), "acme/base");
    assert_eq!(repository_path("acme/base@sha256:aa"), "acme/base");
    assert_eq!(repository_path("acme/base:1@sha256:aa"), "acme/base");
    assert_eq!(
        repository_path("registry.local:5000/vllm"),
        "registry.local:5000/vllm"
    );
    assert_eq!(
        repository_path("registry.local:5000/vllm:v1"),
        "registry.local:5000/vllm"
    );
    assert_eq!(repository_path("vllm"), "vllm");
}

#[test]
fn an_incomplete_observation_cannot_authorise_an_engine_launch() {
    let observed = ObservedWorkloads {
        containers: Vec::new(),
        truncated: true,
        unreadable_lines: 0,
    };
    assert_eq!(
        guard_from_observation(&observed, &ManagedIds::default()),
        ExternalInferenceGuard::Unknown
    );
}

#[test]
fn a_recognised_running_external_engine_blocks_a_managed_launch() {
    let observed = ObservedWorkloads {
        containers: vec![container(
            Some("existing-vllm"),
            Some("vllm/vllm-openai:v0.11.0"),
        )],
        truncated: false,
        unreadable_lines: 0,
    };
    assert_eq!(
        guard_from_observation(&observed, &ManagedIds::default()),
        ExternalInferenceGuard::Active
    );
}

#[test]
fn custom_images_remain_unowned_and_block_launch_until_their_state_is_known() {
    for state in [
        "running",
        "paused",
        "restarting",
        "created",
        "unknown",
        "exited",
        "dead",
    ] {
        let mut custom = container(
            Some("custom-cluster"),
            Some("ghcr.io/anemll/dspark-vllm-gx10:0.1.1"),
        );
        custom.state = state.into();
        assert_eq!(
            classify(&custom, &ManagedIds::default()).ownership,
            "unknown_external"
        );
        let observed = ObservedWorkloads {
            containers: vec![custom],
            truncated: false,
            unreadable_lines: 0,
        };
        let expected = if matches!(state, "exited" | "dead") {
            ExternalInferenceGuard::Clear
        } else {
            ExternalInferenceGuard::Unknown
        };
        assert_eq!(
            guard_from_observation(&observed, &ManagedIds::default()),
            expected,
            "{state}"
        );
    }
}

#[test]
fn owned_project_containers_and_recognized_optional_services_do_not_block_inference() {
    let observed = ObservedWorkloads {
        containers: vec![
            container(
                Some(&format!("spark-project-{MANAGED_WORKTREE_ID}")),
                Some("debian:bookworm"),
            ),
            container(
                Some("existing-webui"),
                Some("ghcr.io/open-webui/open-webui:main"),
            ),
        ],
        truncated: false,
        unreadable_lines: 0,
    };
    assert_eq!(
        guard_from_observation(&observed, &recorded()),
        ExternalInferenceGuard::Clear
    );
}

#[test]
fn the_helpers_own_voice_and_search_services_never_block_a_launch() {
    // A managed Kokoro container must not be mistaken for an external inference engine.
    let observed = ObservedWorkloads {
        containers: vec![
            container(
                Some(spark_privd::kokoro::CONTAINER),
                Some(spark_privd::kokoro::IMAGE),
            ),
            container(
                Some(spark_privd::searxng::CONTAINER),
                Some(spark_privd::searxng::IMAGE),
            ),
        ],
        truncated: false,
        unreadable_lines: 0,
    };
    for service in &observed.containers {
        let classification = classify(service, &ManagedIds::default());
        assert_eq!(
            classification.ownership, "spark_managed",
            "{:?}",
            service.name
        );
        assert_eq!(
            classification.kind, "optional_service",
            "{:?}",
            service.name
        );
    }
    assert_eq!(
        guard_from_observation(&observed, &ManagedIds::default()),
        ExternalInferenceGuard::Clear
    );
}

#[test]
fn a_kokoro_or_searxng_image_under_another_name_is_a_recognised_service_not_an_engine() {
    let observed = ObservedWorkloads {
        containers: vec![
            container(
                Some("my-tts"),
                Some("ghcr.io/remsky/kokoro-fastapi-gpu:latest"),
            ),
            container(Some("search"), Some("docker.io/searxng/searxng:2026.9.4")),
        ],
        truncated: false,
        unreadable_lines: 0,
    };
    for service in &observed.containers {
        let classification = classify(service, &ManagedIds::default());
        assert_eq!(
            classification.ownership, "external_observed",
            "{:?}",
            service.name
        );
        assert_eq!(
            classification.kind, "optional_service",
            "{:?}",
            service.name
        );
    }
    assert_eq!(
        guard_from_observation(&observed, &ManagedIds::default()),
        ExternalInferenceGuard::Clear
    );
}

#[test]
fn an_external_ray_cluster_does_not_prove_its_gpus_are_idle() {
    let observed = ObservedWorkloads {
        containers: vec![container(
            Some("ray-worker"),
            Some("rayproject/ray-ml:2.49.1"),
        )],
        truncated: false,
        unreadable_lines: 0,
    };
    assert_eq!(
        guard_from_observation(&observed, &ManagedIds::default()),
        ExternalInferenceGuard::Unknown
    );
}

#[tokio::test]
async fn an_external_openai_endpoint_exposes_only_verified_model_aliases() {
    let listener = tokio::net::TcpListener::bind(("127.0.0.1", 0))
        .await
        .expect("bind model endpoint");
    let port = listener
        .local_addr()
        .expect("model endpoint address")
        .port();
    let app = axum::Router::new().route(
        "/v1/models",
        axum::routing::get(|| async {
            Json(json!({
                "object": "list",
                "data": [{
                    "id": "deepseek-ai/DeepSeek-R1",
                    "object": "model",
                    "api_key": "should-never-leave-the-probe",
                }],
                "token": "also-not-a-model-field",
            }))
        }),
    );
    tokio::spawn(async move {
        axum::serve(listener, app)
            .await
            .expect("serve model endpoint");
    });

    let mut observed = container(Some("existing-vllm"), Some("vllm/vllm-openai:v0.11.0"));
    observed.ports.push(ObservedPort {
        host_ip: "0.0.0.0".into(),
        host_port: port,
        container_port: 8000,
        protocol: "tcp".into(),
    });
    let classification = classify(&observed, &ManagedIds::default());
    let mut probe_budget = 4;
    let configuration =
        observe_external_configuration(&observed, classification, &mut probe_budget).await;

    assert_eq!(configuration.state, "verified");
    assert_eq!(configuration.api_protocol, Some("openai_compatible"));
    assert_eq!(configuration.api_port, Some(port));
    assert_eq!(configuration.served_models, ["deepseek-ai/DeepSeek-R1"]);
    let encoded = serde_json::to_string(&configuration.served_models).unwrap();
    assert!(!encoded.contains("should-never-leave-the-probe"));
    assert!(!encoded.contains("also-not-a-model-field"));
}

#[tokio::test]
async fn conflicting_external_model_endpoints_are_reported_as_ambiguous() {
    async fn endpoint(model: &'static str) -> u16 {
        let listener = tokio::net::TcpListener::bind(("127.0.0.1", 0))
            .await
            .expect("bind model endpoint");
        let port = listener
            .local_addr()
            .expect("model endpoint address")
            .port();
        let app = axum::Router::new().route(
            "/v1/models",
            axum::routing::get(move || async move {
                Json(json!({
                    "object": "list",
                    "data": [{"id": model, "object": "model"}],
                }))
            }),
        );
        tokio::spawn(async move {
            axum::serve(listener, app)
                .await
                .expect("serve model endpoint");
        });
        port
    }

    let first = endpoint("one/model").await;
    let second = endpoint("another/model").await;
    let mut observed = container(Some("existing-vllm"), Some("vllm/vllm-openai:v0.11.0"));
    for port in [first, second] {
        observed.ports.push(ObservedPort {
            host_ip: "0.0.0.0".into(),
            host_port: port,
            container_port: 8000,
            protocol: "tcp".into(),
        });
    }
    let classification = classify(&observed, &ManagedIds::default());
    let mut probe_budget = 4;
    let configuration =
        observe_external_configuration(&observed, classification, &mut probe_budget).await;
    assert_eq!(configuration, ExternalConfiguration::ambiguous());
}
