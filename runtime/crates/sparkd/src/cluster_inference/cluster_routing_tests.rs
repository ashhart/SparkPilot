use super::*;
use std::sync::Arc;

use axum::body::Bytes;
use serde_json::json;

use crate::auth::Principal;
use spark_core::identity::NodeIdentity;
use spark_telemetry::FakeSystemMonitor;

struct UnusedClusterLink;

impl crate::cluster_coordination::ClusterLinkControl for UnusedClusterLink {
    fn apply(
        &self,
        _: &crate::cluster_coordination::ClusterProposal,
        _: uuid::Uuid,
        _: spark_privd::protocol::ClusterLinkPhase,
    ) -> Result<(), crate::cluster_coordination::CoordinationError> {
        unreachable!("route resolution never changes the cluster link")
    }

    fn prove(
        &self,
        _: &crate::cluster_coordination::ClusterProposal,
        _: uuid::Uuid,
    ) -> Result<
        crate::cluster_coordination::ClusterLinkProof,
        crate::cluster_coordination::CoordinationError,
    > {
        unreachable!("route resolution never probes the cluster link")
    }
}

fn routed_state(
    launch_suffix: u128,
) -> (
    tempfile::TempDir,
    AppState,
    uuid::Uuid,
    uuid::Uuid,
    uuid::Uuid,
    crate::cluster_coordination::DistributedExecutionSpec,
) {
    let directory = tempfile::tempdir().unwrap();
    let coordinator_identity = NodeIdentity::generate("coordinator");
    let worker_identity = NodeIdentity::generate("worker");
    let owner_device_id = uuid::Uuid::new_v4();
    let cluster_id = uuid::Uuid::new_v4();
    let transaction_id = uuid::Uuid::new_v4();
    let launch_id = uuid::Uuid::from_u128(launch_suffix);
    let image = format!("registry.example/vllm@sha256:{}", "a".repeat(64));
    let member = |identity: &NodeIdentity| crate::cluster_coordination::ClusterMemberDescriptor {
        node_id: identity.node_id(),
        name: identity.public.node_name.clone(),
        authority_public_key: identity.public.authority_public_key.clone(),
        authority_fingerprint: identity.public.authority_fingerprint.clone(),
        runtime_version: "0.1.0".into(),
        engine_image: image.clone(),
    };
    let expires_at = (time::OffsetDateTime::now_utc() + time::Duration::minutes(5))
        .format(&time::format_description::well_known::Rfc3339)
        .unwrap();
    let proposal = crate::cluster_coordination::ClusterProposal {
        version: 1,
        transaction_id,
        cluster_id,
        name: "Studio pair".into(),
        coordinator_node_id: coordinator_identity.node_id(),
        owner_device_id,
        expires_at,
        members: vec![member(&coordinator_identity), member(&worker_identity)],
    };
    let proposal_digest = proposal.digest().unwrap();
    let execution = crate::cluster_coordination::DistributedExecutionSpec {
        recipe_id: "example/model-32b".into(),
        profile_id: "balanced-16k".into(),
        recipe_digest: "b".repeat(64),
        source_revision: "c".repeat(40),
        image_digest: image,
        served_name: "example-32b".into(),
        model_snapshot: "/var/lib/spark/models/example/model-32b".into(),
        host_port: 18_100 + ((launch_id.as_u128() as u32) % 100) as u16,
        gpu_memory_utilisation_milli: 720,
        max_model_length: 16_384,
        max_sequences: 4,
        max_batched_tokens: 8_192,
        tensor_parallel_size: 2,
    };
    execution.validate(launch_id).unwrap();

    let mut connection = rusqlite::Connection::open_in_memory().unwrap();
    crate::migration::migrate(&mut connection).unwrap();
    crate::store::insert_device(
        &connection,
        &owner_device_id,
        "Owner",
        "macos",
        b"owner-key",
        &"d".repeat(64),
        "owner",
    )
    .unwrap();
    let now = crate::store::now_iso8601();
    connection
        .execute(
            "INSERT INTO cluster_state(singleton,id,name,state,created_at,updated_at)
             VALUES(1,?1,'Studio pair','ready',?2,?2)",
            rusqlite::params![cluster_id.to_string(), now],
        )
        .unwrap();
    for (identity, role) in [
        (&coordinator_identity, "leader"),
        (&worker_identity, "worker"),
    ] {
        connection
            .execute(
                "INSERT INTO cluster_members
                 (cluster_id,node_id,name,role,authority_fingerprint,reachable,
                  runtime_version,last_seen_at,metadata_json)
                 VALUES(?1,?2,?3,?4,?5,1,'0.1.0',?6,'{}')",
                rusqlite::params![
                    cluster_id.to_string(),
                    identity.node_id().to_string(),
                    identity.public.node_name,
                    role,
                    identity.public.authority_fingerprint,
                    now,
                ],
            )
            .unwrap();
    }
    connection
        .execute(
            "INSERT INTO cluster_transactions
             (transaction_id,cluster_id,proposal_digest,coordinator_node_id,
              owner_device_id,local_address,peer_address,state,proposal_json,
              grant_json,created_at,updated_at)
             VALUES(?1,?2,?3,?4,?5,'172.31.252.1','172.31.252.2','ready',?6,'{}',?7,?7)",
            rusqlite::params![
                transaction_id.to_string(),
                cluster_id.to_string(),
                proposal_digest,
                coordinator_identity.node_id().to_string(),
                owner_device_id.to_string(),
                serde_json::to_string(&proposal).unwrap(),
                now,
            ],
        )
        .unwrap();
    connection
        .execute(
            "INSERT INTO cluster_launches
             (launch_id,cluster_id,recipe_id,profile_id,execution_spec_json,state,
              coordinator_node_id,worker_node_id,created_at,updated_at)
             VALUES(?1,?2,?3,?4,?5,'running',?6,?7,?8,?8)",
            rusqlite::params![
                launch_id.to_string(),
                cluster_id.to_string(),
                execution.recipe_id,
                execution.profile_id,
                serde_json::to_string(&execution).unwrap(),
                coordinator_identity.node_id().to_string(),
                worker_identity.node_id().to_string(),
                now,
            ],
        )
        .unwrap();
    let database = Arc::new(parking_lot::Mutex::new(connection));
    let state = AppState::new(
        crate::state::RuntimeConfig {
            api_major: 1,
            runtime_version: "0.1.0".into(),
            listen: "127.0.0.1:0".parse().unwrap(),
            node_name: "coordinator".into(),
            data_dir: directory.path().to_path_buf(),
            advertise: false,
            tls: false,
        },
        coordinator_identity,
        Arc::new(FakeSystemMonitor),
        None,
    )
    .with_database(database.clone());
    let cluster = Arc::new(crate::cluster::ClusterService::new(
        database.clone(),
        state.events.clone(),
        state.identity.node_id().to_string(),
        Arc::new(crate::cluster::NoLinkProbe),
        Arc::new(crate::cluster::NoCollectiveTest),
    ));
    let coordinator = Arc::new(
        crate::cluster_coordination::ClusterCoordinationService::new(
            database,
            state.identity.clone(),
            Arc::new(UnusedClusterLink),
            Arc::new(crate::cluster_coordination::NoDistributedRuntime),
        ),
    );
    (
        directory,
        state
            .with_cluster(cluster)
            .with_cluster_coordination(coordinator),
        cluster_id,
        launch_id,
        owner_device_id,
        execution,
    )
}

#[test]
fn unqualified_running_cluster_is_refused_for_chat_and_analysis() {
    let (_directory, state, cluster_id, _launch_id, _owner_device_id, execution) = routed_state(71);
    for result in [
        cluster_inference_route(&state, None, Some(&execution.served_name), true, false),
        cluster_inference_route(&state, Some(&cluster_id.to_string()), None, false, false),
    ] {
        let (status, Json(value)) = match result {
            Ok(_) => panic!("an unqualified cluster route was accepted"),
            Err(error) => error,
        };
        assert_eq!(status, StatusCode::CONFLICT);
        assert_eq!(value["error"]["code"], "CLUSTER_INFERENCE_UNAVAILABLE");
    }
    let omitted_target = crate::analysis_api::check_target_with_qualification(&state, None, false);
    let (_, Json(value)) = match omitted_target {
        Ok(_) => panic!("an omitted cluster target bypassed qualification"),
        Err(error) => error,
    };
    assert_eq!(value["error"]["code"], "CLUSTER_INFERENCE_UNAVAILABLE");
}

#[test]
fn qualified_running_owned_launch_routes_chat_and_analysis_to_exact_loopback_engine() {
    let (_directory, state, cluster_id, launch_id, _owner_device_id, execution) = routed_state(72);
    let chat = cluster_inference_route(&state, None, Some(&execution.recipe_id), true, true)
        .unwrap()
        .unwrap();
    let analysis =
        cluster_inference_route(&state, Some(&cluster_id.to_string()), None, false, true)
            .unwrap()
            .unwrap();
    let inferred_analysis =
        crate::analysis_api::check_target_with_qualification(&state, None, true)
            .unwrap()
            .unwrap();

    for route in [chat, analysis, inferred_analysis] {
        assert_eq!(route.cluster_id, cluster_id);
        assert_eq!(route.launch_id, launch_id);
        assert_eq!(route.upstream.host_port, execution.host_port);
        assert_eq!(route.upstream.model_id, execution.recipe_id);
        assert_eq!(route.upstream.served_name, execution.served_name);
        assert!(route.upstream.api_key.is_empty());
    }
}

async fn cluster_completion(Json(request): Json<Value>) -> Json<Value> {
    Json(json!({
        "id": "cluster-completion",
        "object": "chat.completion",
        "created": 1,
        "model": request["model"],
        "choices": [{
            "index": 0,
            "message": { "role": "assistant", "content": "cluster answer" },
            "finish_reason": "stop"
        }],
        "usage": { "prompt_tokens": 4, "completion_tokens": 2, "total_tokens": 6 }
    }))
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn qualified_chat_and_analysis_handlers_use_the_managed_cluster_engine() {
    let (_directory, state, cluster_id, _launch_id, owner_device_id, execution) = routed_state(73);
    let listener = tokio::net::TcpListener::bind(("127.0.0.1", execution.host_port))
        .await
        .unwrap();
    let upstream = tokio::spawn(async move {
        axum::serve(
            listener,
            axum::Router::new()
                .route("/health", axum::routing::get(|| async { StatusCode::OK }))
                .route(
                    "/v1/chat/completions",
                    axum::routing::post(cluster_completion),
                ),
        )
        .await
        .unwrap();
    });
    let principal = Principal {
        device_id: owner_device_id,
        role: "owner".into(),
        access_authentication: crate::auth::AccessAuthentication::DeviceSignature,
        user_presence: None,
    };
    let chat_body = Bytes::from(
        serde_json::to_vec(&json!({
            "model": execution.recipe_id,
            "messages": [{ "role": "user", "content": "hello" }],
            "stream": false,
        }))
        .unwrap(),
    );
    let response = crate::engine_api::chat_completions_with_qualification(
        state.clone(),
        principal.clone(),
        chat_body,
        true,
    )
    .await
    .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let response_body = axum::body::to_bytes(response.into_body(), 1 << 20)
        .await
        .unwrap();
    let response_json: Value = serde_json::from_slice(&response_body).unwrap();
    assert_eq!(response_json["model"], execution.served_name);
    assert_eq!(
        response_json["choices"][0]["message"]["content"],
        "cluster answer"
    );

    let analysis_body = Bytes::from(
        serde_json::to_vec(&json!({
            "instruction": "Summarise this.",
            "text": "Private cluster document.",
            "target": { "cluster_id": cluster_id },
        }))
        .unwrap(),
    );
    let idempotency = crate::idempotency::IdempotencyRequest {
        device_id: owner_device_id,
        method: "POST".into(),
        path: "/api/v1/inference/analyses".into(),
        key: uuid::Uuid::new_v4(),
        body_hash: "cluster-analysis".into(),
        request_id: Some(uuid::Uuid::new_v4()),
    };
    let (status, Json(accepted)) = crate::analysis_api::start_analysis_with_qualification(
        state.clone(),
        principal,
        idempotency,
        analysis_body,
        true,
    )
    .await
    .unwrap();
    assert_eq!(status, StatusCode::ACCEPTED, "{accepted}");
    let operation_id = accepted["id"].as_str().unwrap().to_owned();
    let mut finished = None;
    for _ in 0..200 {
        let row: Option<(String, Option<String>)> = state
            .database
            .as_ref()
            .unwrap()
            .lock()
            .query_row(
                "SELECT state,result_json FROM operations WHERE id=?1",
                [&operation_id],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .optional()
            .unwrap();
        if row.as_ref().is_some_and(|(state, _)| {
            matches!(state.as_str(), "succeeded" | "failed" | "cancelled")
        }) {
            finished = row;
            break;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    let (state_name, result_json) = finished.expect("analysis reached a terminal state");
    assert_eq!(state_name, "succeeded");
    let result: Value = serde_json::from_str(result_json.as_deref().unwrap()).unwrap();
    assert_eq!(result["text"], "cluster answer");
    assert_eq!(result["model_id"], execution.recipe_id);
    upstream.abort();
}

#[tokio::test]
async fn a_stale_running_row_cannot_route_without_live_loopback_health() {
    let (_directory, state, _cluster_id, _launch_id, _owner_device_id, execution) =
        routed_state(74);
    let listener = tokio::net::TcpListener::bind(("127.0.0.1", execution.host_port))
        .await
        .expect("the reserved cluster test port is available");
    drop(listener);
    let route = cluster_inference_route(&state, None, Some(&execution.recipe_id), true, true)
        .unwrap()
        .unwrap();
    let (_, Json(value)) = verify_cluster_route_health(&route).await.unwrap_err();
    assert_eq!(value["error"]["code"], "ENGINE_NOT_READY");
}

#[test]
fn revoked_owner_and_tampered_execution_spec_fail_closed() {
    let (_directory, state, _cluster_id, launch_id, owner_device_id, execution) = routed_state(75);
    crate::store::insert_device(
        &state.database.as_ref().unwrap().lock(),
        &uuid::Uuid::new_v4(),
        "Backup owner",
        "ios",
        b"backup-owner-key",
        &"e".repeat(64),
        "owner",
    )
    .unwrap();
    state
        .database
        .as_ref()
        .unwrap()
        .lock()
        .execute(
            "UPDATE devices SET revoked_at=?1 WHERE id=?2",
            rusqlite::params![crate::store::now_iso8601(), owner_device_id.to_string()],
        )
        .unwrap();
    let (_, Json(value)) =
        match cluster_inference_route(&state, None, Some(&execution.recipe_id), true, true) {
            Ok(_) => panic!("a revoked cluster owner still authorised routing"),
            Err(error) => error,
        };
    assert_eq!(value["error"]["code"], "ROLE_FORBIDDEN");

    state
        .database
        .as_ref()
        .unwrap()
        .lock()
        .execute(
            "UPDATE devices SET revoked_at=NULL WHERE id=?1",
            [owner_device_id.to_string()],
        )
        .unwrap();
    let mut tampered = execution;
    tampered.host_port = 80;
    state
        .database
        .as_ref()
        .unwrap()
        .lock()
        .execute(
            "UPDATE cluster_launches SET execution_spec_json=?1 WHERE launch_id=?2",
            rusqlite::params![
                serde_json::to_string(&tampered).unwrap(),
                launch_id.to_string(),
            ],
        )
        .unwrap();
    let (status, Json(value)) =
        match cluster_inference_route(&state, None, Some(&tampered.recipe_id), true, true) {
            Ok(_) => panic!("a caller-controlled upstream port was accepted"),
            Err(error) => error,
        };
    assert_eq!(status, StatusCode::INTERNAL_SERVER_ERROR);
    assert_eq!(value["error"]["code"], "INTERNAL_ERROR");
}
