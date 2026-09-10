//! Exercise signed agent plan/edit/test/diff/review, approval merge, rejection audit and tool allowlist behavior.

const SIGNING_NODE_ID: uuid::Uuid = uuid::Uuid::from_u128(2);

use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Duration;

use p256::ecdsa::signature::Signer as _;
use p256::pkcs8::EncodePublicKey;
use rand::RngCore;
use serde_json::{Value, json};
use spark_core::identity::{FileIdentityStore, IdentityStore};
use spark_project_runner::{CommandGit, FakeContainerBoundary, GitRunner, ScriptedPtyRunner};
use sparkd::agent::{
    AgentPolicy, AgentService, AgentToolCall, AgentToolExecutor, GitOp, ScriptedBrain,
    ToolExecutionTarget, ToolRuntime,
};
use sparkd::crypto::{base64url_encode, sha256_hex};
use sparkd::migration;
use sparkd::project::ProjectManager;
use sparkd::route::router;
use sparkd::state::{AppState, RuntimeConfig};

struct Harness {
    state: AppState,
    agents: Arc<AgentService>,
    _dir: tempfile::TempDir,
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

fn spki_der(key: &p256::ecdsa::SigningKey) -> Vec<u8> {
    key.verifying_key()
        .to_public_key_der()
        .expect("spki der")
        .as_bytes()
        .to_vec()
}

async fn harness(
    plan: Vec<AgentToolCall>,
) -> (Harness, SocketAddr, p256::ecdsa::SigningKey, uuid::Uuid) {
    let dir = tempfile::tempdir().expect("tempdir");
    let mut identity = FileIdentityStore::new(dir.path().join("identity"))
        .load_or_create("agent-test")
        .expect("identity");
    identity.public.node_id = SIGNING_NODE_ID;

    let mut conn = rusqlite::Connection::open_in_memory().expect("db");
    migration::migrate(&mut conn).expect("migrate");
    let database = Arc::new(parking_lot::Mutex::new(conn));
    let jobs = sparkd::jobs::JobService::new();
    let events = sparkd::events::EventBus::new();

    let projects = Arc::new(ProjectManager::new(
        Arc::new(CommandGit::new("git")),
        Arc::new(FakeContainerBoundary::default()),
        Arc::new(ScriptedPtyRunner::default()),
        database.clone(),
        jobs.clone(),
        events.clone(),
        identity.node_id().to_string(),
        dir.path().join("projects"),
        dir.path().join("worktrees"),
    ));
    let agents = Arc::new(AgentService::new(
        projects.clone(),
        jobs.clone(),
        events.clone(),
        identity.node_id().to_string(),
        Box::new(ScriptedBrain::plan(plan)),
        Arc::new(ToolRuntime::new(AgentPolicy {
            allowlist_commands: vec!["true".into(), "false".into()],
        })),
    ));

    let config = RuntimeConfig {
        api_major: 1,
        runtime_version: "0.1.0".to_owned(),
        listen: "127.0.0.1:0".parse().unwrap(),
        node_name: "agent-test".to_owned(),
        data_dir: dir.path().to_path_buf(),
        advertise: false,
        tls: false,
    };
    let state = AppState::new(
        config,
        identity,
        Arc::new(spark_telemetry::FakeSystemMonitor),
        None,
    )
    .with_database(database)
    .with_projects(projects)
    .with_agents(agents.clone());

    let listener = tokio::net::TcpListener::bind(("127.0.0.1", 0))
        .await
        .expect("bind");
    let addr = listener.local_addr().expect("addr");
    let served = state.clone();
    tokio::spawn(async move {
        axum::serve(listener, router(served)).await.expect("serve");
    });

    let device_key = fresh_device_key();
    let device_id = uuid::Uuid::new_v4();
    {
        let conn = state.database.as_ref().expect("db").lock();
        sparkd::store::insert_device(
            &conn,
            &device_id,
            "agent-device",
            "macos",
            &spki_der(&device_key),
            &format!("fp-agent-{device_id}"),
            "owner",
        )
        .expect("seed owner");
    }

    (
        Harness {
            state,
            agents,
            _dir: dir,
        },
        addr,
        device_key,
        device_id,
    )
}

fn fresh_nonce() -> String {
    let mut nonce = [0u8; 24];
    rand::rng().fill_bytes(&mut nonce);
    base64url_encode(&nonce)
}

fn rfc3339_now() -> String {
    time::OffsetDateTime::now_utc()
        .format(&time::format_description::well_known::Rfc3339)
        .expect("rfc3339")
}

fn signed_parts(
    device_key: &p256::ecdsa::SigningKey,
    device_id: &uuid::Uuid,
    method: &str,
    path: &str,
    body: &[u8],
) -> (Vec<(String, String)>, Vec<u8>) {
    signed_parts_with_idempotency(
        device_key,
        device_id,
        method,
        path,
        body,
        uuid::Uuid::new_v4(),
    )
}

fn signed_parts_with_idempotency(
    device_key: &p256::ecdsa::SigningKey,
    device_id: &uuid::Uuid,
    method: &str,
    path: &str,
    body: &[u8],
    idempotency_key: uuid::Uuid,
) -> (Vec<(String, String)>, Vec<u8>) {
    let timestamp = rfc3339_now();
    let nonce = fresh_nonce();
    let digest = sha256_hex(body);
    let canonical = sparkd::auth::canonical(
        method,
        path,
        &timestamp,
        &nonce,
        &digest,
        device_id,
        &SIGNING_NODE_ID,
    );
    let signature: p256::ecdsa::Signature = device_key.sign(canonical.as_bytes());
    let mut headers = vec![
        ("idempotency-key".to_owned(), idempotency_key.to_string()),
        ("x-spark-node-id".to_owned(), SIGNING_NODE_ID.to_string()),
        ("x-spark-device-id".to_owned(), device_id.to_string()),
        ("x-spark-timestamp".to_owned(), timestamp),
        ("x-spark-nonce".to_owned(), nonce),
        ("x-spark-content-sha256".to_owned(), digest),
        (
            "x-spark-signature".to_owned(),
            base64url_encode(&signature.to_bytes()),
        ),
    ];
    if !body.is_empty() {
        headers.push(("content-type".to_owned(), "application/json".to_owned()));
    }
    (headers, body.to_vec())
}

async fn signed_json(
    client: &reqwest::Client,
    base: SocketAddr,
    device_key: &p256::ecdsa::SigningKey,
    device_id: &uuid::Uuid,
    method: &str,
    path: &str,
    body: Option<Value>,
) -> (reqwest::StatusCode, Value) {
    let body_bytes = body
        .map(|b| serde_json::to_vec(&b).unwrap())
        .unwrap_or_default();
    let (headers, bytes) = signed_parts(device_key, device_id, method, path, &body_bytes);
    let url = format!("http://{base}{path}");
    let mut builder = client.request(
        reqwest::Method::from_bytes(method.as_bytes()).unwrap(),
        &url,
    );
    for (name, value) in headers {
        builder = builder.header(name, value);
    }
    let response = builder.body(bytes).send().await.expect("send");
    let status = response.status();
    let body: Value = response.json().await.unwrap_or(Value::Null);
    (status, body)
}

#[allow(clippy::too_many_arguments)]
async fn signed_json_with_idempotency(
    client: &reqwest::Client,
    base: SocketAddr,
    device_key: &p256::ecdsa::SigningKey,
    device_id: &uuid::Uuid,
    method: &str,
    path: &str,
    body: Option<Value>,
    idempotency_key: uuid::Uuid,
) -> (reqwest::StatusCode, Value) {
    let body_bytes = body
        .map(|value| serde_json::to_vec(&value).unwrap())
        .unwrap_or_default();
    let (headers, bytes) = signed_parts_with_idempotency(
        device_key,
        device_id,
        method,
        path,
        &body_bytes,
        idempotency_key,
    );
    let url = format!("http://{base}{path}");
    let mut builder = client.request(
        reqwest::Method::from_bytes(method.as_bytes()).unwrap(),
        &url,
    );
    for (name, value) in headers {
        builder = builder.header(name, value);
    }
    let response = builder.body(bytes).send().await.expect("send");
    let status = response.status();
    let body: Value = response.json().await.unwrap_or(Value::Null);
    (status, body)
}

/// Create project through the API and return its id (op must succeed).
async fn create_project(
    client: &reqwest::Client,
    base: SocketAddr,
    key: &p256::ecdsa::SigningKey,
    device_id: &uuid::Uuid,
    state: &AppState,
    name: &str,
) -> String {
    let (status, response) = signed_json(
        client,
        base,
        key,
        device_id,
        "POST",
        "/api/v1/projects",
        Some(json!({ "name": name })),
    )
    .await;
    assert_eq!(status, reqwest::StatusCode::ACCEPTED, "{response}");
    let op = response["id"].as_str().unwrap().to_owned();
    wait_ok(state, &op).await;
    let row = {
        let conn = state.database.as_ref().expect("db").lock();
        sparkd::store::project_rows(&conn, 10).unwrap()[0].clone()
    };
    let root = std::path::PathBuf::from(&row.root_path);
    std::fs::create_dir_all(root.join(".devcontainer")).unwrap();
    std::fs::write(
        root.join(".devcontainer/devcontainer.json"),
        r#"{"image":"test.invalid/project@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}"#,
    )
    .unwrap();
    let git = CommandGit::new("git");
    git.run(&root, &["add", "--", ".devcontainer/devcontainer.json"])
        .unwrap();
    git.run(&root, &["commit", "--quiet", "-m", "test project sandbox"])
        .unwrap();
    row.id.to_string()
}

async fn wait_ok(state: &AppState, operation_id: &str) {
    let target = uuid::Uuid::parse_str(operation_id).unwrap();
    let deadline = std::time::Instant::now() + Duration::from_secs(20);
    loop {
        let row = {
            let conn = state.database.as_ref().expect("db").lock();
            state
                .jobs
                .get(&conn, target)
                .expect("get")
                .expect("present")
        };
        let value = serde_json::to_value(&row).unwrap();
        let s = value["state"].as_str().unwrap_or("running");
        if s == "succeeded" {
            return;
        }
        if s == "failed" {
            // Include the stored error code so failed-operation assertions identify the cause.
            let code: Option<String> = {
                let conn = state.database.as_ref().expect("db").lock();
                conn.query_row(
                    "SELECT error_code FROM operations WHERE id = ?1",
                    [target.to_string()],
                    |row| row.get(0),
                )
                .unwrap()
            };
            panic!("operation failed: {value} error_code={code:?}");
        }
        assert!(std::time::Instant::now() < deadline, "timeout {value}");
        tokio::time::sleep(Duration::from_millis(15)).await;
    }
}

/// Poll until the change (by task) reaches the given status.
async fn wait_change_status(state: &AppState, project_id: &str, task: &str, target: &str) -> Value {
    let deadline = std::time::Instant::now() + Duration::from_secs(20);
    loop {
        let rows = {
            let conn = state.database.as_ref().expect("db").lock();
            sparkd::store::change_rows(&conn, &uuid::Uuid::parse_str(project_id).unwrap()).unwrap()
        };
        if let Some(row) = rows.iter().find(|r| r.task == task)
            && row.status == target
        {
            return serde_json::to_value(row).unwrap();
        }
        assert!(std::time::Instant::now() < deadline, "change not {target}");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
}

fn reviewed_file_plan(path: &str, content: &str) -> Vec<AgentToolCall> {
    vec![
        AgentToolCall::WriteFile {
            path: path.into(),
            content: content.into(),
        },
        AgentToolCall::Git {
            op: GitOp::Add { path: path.into() },
        },
        AgentToolCall::Git {
            op: GitOp::Commit {
                message: format!("add {path}"),
            },
        },
        AgentToolCall::RunCommand {
            command: "true".into(),
        },
    ]
}

// Agent lifecycle and approval integration cases.

include!("agent_flow/scenarios/agent_runs_tools_and_reaches_review_with_diff.rs");

include!("agent_flow/scenarios/approval_merges_and_mark_change_merged.rs");

include!(
    "agent_flow/scenarios/approval_recovers_after_the_reviewed_merge_landed_before_status_commit.rs"
);

include!(
    "agent_flow/scenarios/requesting_changes_preserves_audit_and_returns_the_change_to_editing.rs"
);

include!("agent_flow/scenarios/rejection_closes_the_change_and_keeps_its_evidence.rs");

include!("agent_flow/scenarios/synchronous_start_failure_is_the_exact_replayed_response.rs");

include!("agent_flow/scenarios/tool_allowlist_blocks_arbitrary_commands.rs");

include!("agent_flow/scenarios/agent_files_never_follow_symlinks_outside_the_worktree.rs");

include!("agent_flow/scenarios/command_allowlist_matches_the_complete_argv.rs");

include!("agent_flow/scenarios/a_change_without_passing_test_evidence_never_reaches_review.rs");

include!("agent_flow/scenarios/a_failed_test_never_reaches_review.rs");

include!(
    "agent_flow/scenarios/an_agent_without_a_project_container_fails_instead_of_using_the_host.rs"
);

include!("agent_flow/scenarios/git_add_rejects_an_escaping_path_before_invoking_git.rs");

include!("agent_flow/scenarios/an_approval_digest_must_match_the_exact_reviewed_evidence.rs");

include!("agent_flow/scenarios/changing_the_reviewed_worktree_invalidates_approval.rs");

include!("agent_flow/scenarios/protected_head_drift_blocks_the_reviewed_merge.rs");

include!("agent_flow/scenarios/an_unrelated_same_tree_commit_is_not_mistaken_for_a_merge_retry.rs");

async fn wait_until_failed(state: &AppState, operation_id: &str) {
    let target = uuid::Uuid::parse_str(operation_id).unwrap();
    let deadline = std::time::Instant::now() + Duration::from_secs(20);
    loop {
        let row = {
            let conn = state.database.as_ref().expect("db").lock();
            state
                .jobs
                .get(&conn, target)
                .expect("get")
                .expect("present")
        };
        let value = serde_json::to_value(&row).unwrap();
        let s = value["state"].as_str().unwrap_or("running");
        if s == "failed" {
            return;
        }
        assert!(
            std::time::Instant::now() < deadline,
            "op did not fail: {value}"
        );
        tokio::time::sleep(Duration::from_millis(15)).await;
    }
}

include!("agent_flow/scenarios/a_change_cannot_be_approved_through_another_project.rs");

include!("agent_flow/scenarios/a_global_administrator_is_not_an_implicit_approver.rs");
