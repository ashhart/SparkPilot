use super::*;
use axum::extract::{Extension, State};
use futures::StreamExt;
use spark_core::identity::{FileIdentityStore, IdentityStore};
use spark_telemetry::FakeSystemMonitor;

#[tokio::test]
async fn streaming_cluster_chat_emits_typed_peer_loss_before_ending() {
    for loss in [
        crate::cluster_coordination::ClusterPeerLoss::Worker,
        crate::cluster_coordination::ClusterPeerLoss::Coordinator,
    ] {
        let (sender, _) = tokio::sync::watch::channel(None);
        sender.send_replace(Some(loss));
        let ticket = InferenceRequestTicket::cluster_with_sender(&sender);
        let upstream = futures::stream::pending::<Result<Bytes, reqwest::Error>>();
        let mut stream = UsageTee::new(upstream, ticket, None);

        let frame = stream.next().await.unwrap().unwrap();
        let text = String::from_utf8(frame.to_vec()).unwrap();
        assert!(text.contains("event: error"));
        assert!(text.contains(loss.request_failure_code()));
        assert!(stream.next().await.is_none());
    }
}

#[tokio::test]
async fn authenticated_role_refusal_is_audited_without_request_content() {
    let directory = tempfile::tempdir().unwrap();
    let identity = FileIdentityStore::new(directory.path().join("identity"))
        .load_or_create("audit-refusal")
        .unwrap();
    let mut connection = rusqlite::Connection::open_in_memory().unwrap();
    crate::migration::migrate(&mut connection).unwrap();
    let state = AppState::new(
        crate::state::RuntimeConfig {
            api_major: 1,
            runtime_version: "0.1.0".into(),
            listen: "127.0.0.1:0".parse().unwrap(),
            node_name: "audit-refusal".into(),
            data_dir: directory.path().to_path_buf(),
            advertise: false,
            tls: false,
        },
        identity,
        Arc::new(FakeSystemMonitor),
        Some(connection),
    );
    let device_id = uuid::Uuid::new_v4();
    let request_id = uuid::Uuid::new_v4();
    let response = load_inference(
        State(state.clone()),
        Extension(Principal {
            device_id,
            role: "user".into(),
            access_authentication: crate::auth::AccessAuthentication::DeviceSignature,
            user_presence: None,
        }),
        IdempotencyRequest {
            device_id,
            method: "POST".into(),
            path: "/api/v1/inference/load".into(),
            key: uuid::Uuid::new_v4(),
            body_hash: "not-persisted".into(),
            request_id: Some(request_id),
        },
        Json(LoadModelBody {
            model_id: "example/model-32b".into(),
            profile_id: "balanced-32k".into(),
            replace_active: false,
            target: None,
            accepted_preview_digest: Some("a".repeat(64)),
        }),
    )
    .await
    .unwrap_err();
    assert_eq!(response.0, StatusCode::FORBIDDEN);

    let row: (String, String, String, String, String, String) = state
        .database
        .as_ref()
        .unwrap()
        .lock()
        .query_row(
            "SELECT actor_device_id, actor_role, action, resource, result, details_json
               FROM audit_records",
            [],
            |row| {
                Ok((
                    row.get(0)?,
                    row.get(1)?,
                    row.get(2)?,
                    row.get(3)?,
                    row.get(4)?,
                    row.get(5)?,
                ))
            },
        )
        .unwrap();
    assert_eq!(row.0, device_id.to_string());
    assert_eq!(row.1, "user");
    assert_eq!(row.2, "model.operate");
    assert_eq!(row.3, "model/example/model-32b/load");
    assert_eq!(row.4, "refused");
    assert_eq!(row.5, r#"{"deny_reason":"ROLE_FORBIDDEN"}"#);
    assert!(!row.5.contains("balanced-32k"));
    assert!(!row.5.contains("accepted_preview_digest"));
    assert!(!row.5.contains("not-persisted"));
}
