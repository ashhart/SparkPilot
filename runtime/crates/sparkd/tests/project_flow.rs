//! Exercise project lifecycle, conditional file edits, isolated worktrees, container policy, WebSocket terminals and authenticated previews.

const SIGNING_NODE_ID: uuid::Uuid = uuid::Uuid::from_u128(2);

use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Duration;

use futures::{SinkExt, StreamExt};
use p256::ecdsa::signature::Signer as _;
use p256::pkcs8::EncodePublicKey;
use rand::RngCore;
use serde_json::{Value, json};
use spark_core::identity::{FileIdentityStore, IdentityStore};
use spark_project_runner::{CommandGit, FakeContainerBoundary, ScriptedPtyRunner};
use sparkd::crypto::{base64url_encode, sha256_hex};
use sparkd::migration;
use sparkd::project::ProjectManager;
use sparkd::route::router;
use sparkd::state::{AppState, RuntimeConfig};

const REVISION_EMPTY: &str = "0000000000000000000000000000000000000000000000000000000000000000";

#[path = "project_flow/fixture.rs"]
mod fixture;
use fixture::{Harness, fresh_device_key, harness, harness_with_git, spki_der};

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
    let body = response.json().await.unwrap_or(Value::Null);
    (status, body)
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

/// PUT a file with an explicit If-Match; returns (status, body JSON).
#[allow(clippy::too_many_arguments)]
async fn put_file(
    client: &reqwest::Client,
    base: SocketAddr,
    key: &p256::ecdsa::SigningKey,
    device_id: &uuid::Uuid,
    project_id: &str,
    path: &str,
    content: &str,
    if_match: &str,
) -> (reqwest::StatusCode, Value) {
    put_file_with_idempotency(
        client,
        base,
        key,
        device_id,
        project_id,
        path,
        content,
        if_match,
        uuid::Uuid::new_v4(),
    )
    .await
}

#[allow(clippy::too_many_arguments)]
async fn put_file_with_idempotency(
    client: &reqwest::Client,
    base: SocketAddr,
    key: &p256::ecdsa::SigningKey,
    device_id: &uuid::Uuid,
    project_id: &str,
    path: &str,
    content: &str,
    if_match: &str,
    idempotency_key: uuid::Uuid,
) -> (reqwest::StatusCode, Value) {
    let body = content.as_bytes();
    let (headers, bytes) = signed_parts_with_idempotency(
        key,
        device_id,
        "PUT",
        &format!("/api/v1/projects/{project_id}/files/{path}"),
        body,
        idempotency_key,
    );
    let url = format!("http://{base}/api/v1/projects/{project_id}/files/{path}");
    let mut builder = client.put(url).header("If-Match", if_match);
    for (name, value) in headers {
        builder = builder.header(name, value);
    }
    let response = builder.body(bytes).send().await.expect("send");
    let status = response.status();
    let value: Value = response.json().await.unwrap_or(Value::Null);
    (status, value)
}

async fn wait_op(state: &AppState, operation_id: uuid::Uuid, timeout: Duration) -> String {
    let deadline = std::time::Instant::now() + timeout;
    loop {
        let row = {
            let conn = state.database.as_ref().expect("db").lock();
            state
                .jobs
                .get(&conn, operation_id)
                .expect("get")
                .expect("present")
        };
        let value = serde_json::to_value(&row).unwrap();
        let state_name = value
            .get("state")
            .and_then(Value::as_str)
            .unwrap_or("running");
        if state_name == "succeeded" || state_name == "failed" {
            return state_name.to_owned();
        }
        assert!(
            std::time::Instant::now() < deadline,
            "op {} unfinished: {value}",
            operation_id
        );
        tokio::time::sleep(Duration::from_millis(15)).await;
    }
}

async fn create_through_api(
    client: &reqwest::Client,
    base: SocketAddr,
    key: &p256::ecdsa::SigningKey,
    device_id: &uuid::Uuid,
    name: &str,
) -> uuid::Uuid {
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
    let operation_id: uuid::Uuid = response["id"]
        .as_str()
        .and_then(|s| uuid::Uuid::parse_str(s).ok())
        .expect("operation id");
    operation_id
}

// Project lifecycle, files, previews and terminal integration cases.

include!("project_flow/scenarios/project_lifecycle_list_and_get.rs");

include!(
    "project_flow/scenarios/project_delete_replays_after_the_first_delete_removed_membership.rs"
);

include!("project_flow/scenarios/file_api_enforces_revision_preconditions.rs");

include!("project_flow/scenarios/worktrees_branch_off_head_and_keep_the_main_checkout_clean.rs");

include!("project_flow/scenarios/devcontainer_plans_are_policy_checked.rs");

/// Provide a pinned devcontainer plan because terminals have no host fallback without a project sandbox.
fn write_devcontainer(root: &std::path::Path) {
    let dev_dir = root.join(".devcontainer");
    std::fs::create_dir_all(&dev_dir).unwrap();
    std::fs::write(
        dev_dir.join("devcontainer.json"),
        r#"{
          "image": "nvcr.io/nvidia/cuda@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        }"#,
    )
    .unwrap();
}

include!("project_flow/scenarios/a_project_without_a_container_gets_no_terminal.rs");

include!("project_flow/scenarios/a_terminal_names_a_shell_never_a_command.rs");

include!("project_flow/scenarios/terminal_sessions_drive_over_websocket.rs");

fn ws_url_http(_addr: &SocketAddr, project_id: &str, terminal_id: &str) -> String {
    format!("/api/v1/projects/{project_id}/terminals/{terminal_id}/ws")
}

/// Send a signed WebSocket attach and return the server's handshake status.
async fn attempt_attach(
    addr: SocketAddr,
    key: &p256::ecdsa::SigningKey,
    device_id: &uuid::Uuid,
    project_id: &str,
    terminal_id: &str,
) -> u16 {
    let path = ws_url_http(&addr, project_id, terminal_id);
    let (headers, _) = signed_parts(key, device_id, "GET", &path, &[]);
    let mut request: tokio_tungstenite::tungstenite::http::Request<()> =
        tokio_tungstenite::tungstenite::http::Request::builder()
            .method("GET")
            .uri(format!("ws://{addr}{path}"))
            .header("host", addr.to_string())
            .header("connection", "Upgrade")
            .header("upgrade", "websocket")
            .header("sec-websocket-version", "13")
            .header(
                "sec-websocket-key",
                tokio_tungstenite::tungstenite::handshake::client::generate_key(),
            )
            .body(())
            .expect("build request");
    for (name, value) in headers {
        use tokio_tungstenite::tungstenite::http::{HeaderName, HeaderValue};
        request.headers_mut().insert(
            HeaderName::from_bytes(name.as_bytes()).expect("header name"),
            HeaderValue::from_str(&value).expect("header value"),
        );
    }
    match tokio_tungstenite::connect_async(request).await {
        Ok(_) => 101,
        Err(tokio_tungstenite::tungstenite::Error::Http(response)) => response.status().as_u16(),
        Err(other) => panic!("unexpected websocket failure: {other}"),
    }
}

/// Pair a second owner device that is a member of its own project only.
async fn second_project_and_device(
    h: &Harness,
    addr: SocketAddr,
) -> (p256::ecdsa::SigningKey, uuid::Uuid, uuid::Uuid) {
    let client = reqwest::Client::new();
    let key = fresh_device_key();
    let device_id = uuid::Uuid::new_v4();
    {
        let conn = h.state.database.as_ref().expect("db").lock();
        sparkd::store::insert_device(
            &conn,
            &device_id,
            "second-device",
            "macos",
            &spki_der(&key),
            &format!("fp-second-{device_id}"),
            "owner",
        )
        .expect("seed second owner");
    }
    let operation_id = create_through_api(&client, addr, &key, &device_id, "other").await;
    assert_eq!(
        wait_op(&h.state, operation_id, Duration::from_secs(20)).await,
        "succeeded"
    );
    let other_project = h
        .projects
        .list()
        .unwrap()
        .into_iter()
        .find(|project| project.name == "other")
        .expect("second project")
        .id;
    (key, device_id, other_project)
}

include!("project_flow/scenarios/terminals_cannot_be_reached_through_another_project.rs");

include!("project_flow/scenarios/closing_a_terminal_releases_the_session.rs");

include!("project_flow/scenarios/preview_proxy_serves_registered_ports_with_csp.rs");
include!("project_flow/scenarios/preview_proxy_bounds_upstream_bodies.rs");
include!("project_flow/scenarios/preview_proxy_forwards_the_path_encoded_and_never_a_query.rs");

include!("project_flow/scenarios/the_file_api_never_follows_a_link_out_of_the_project.rs");

#[allow(clippy::too_many_arguments)]
async fn signed_json_bytes(
    client: &reqwest::Client,
    base: SocketAddr,
    key: &p256::ecdsa::SigningKey,
    device_id: &uuid::Uuid,
    method: &str,
    path: &str,
    body: &[u8],
    extra: &[(&str, String)],
) -> (reqwest::StatusCode, Value) {
    let (headers, bytes) = signed_parts(key, device_id, method, path, body);
    let url = format!("http://{base}{path}");
    let mut builder = client.request(
        reqwest::Method::from_bytes(method.as_bytes()).unwrap(),
        &url,
    );
    for (name, value) in headers {
        builder = builder.header(name, value);
    }
    for (name, value) in extra {
        builder = builder.header(*name, value.clone());
    }
    let response = builder.body(bytes).send().await.expect("send");
    let status = response.status();
    let body: Value = response.json().await.unwrap_or(Value::Null);
    (status, body)
}

include!("project_flow/scenarios/the_shared_reserved_port_range_matches_the_engine.rs");

include!("project_flow/scenarios/the_preview_registry_refuses_reserved_engine_ports.rs");

include!("project_flow/scenarios/repository_project_checks_out_the_requested_revision.rs");

include!("project_flow/scenarios/project_file_apis_refuse_git_control_data.rs");

include!("project_flow/scenarios/cold_terminal_uses_a_managed_isolated_checkout.rs");
include!("project_flow/scenarios/terminal_attachment_closes_after_grants_change.rs");

#[derive(Default)]
struct RecordingProjectGit(parking_lot::Mutex<Vec<Vec<String>>>);

impl spark_project_runner::GitRunner for RecordingProjectGit {
    fn run(&self, _repo: &std::path::Path, args: &[&str]) -> Result<String, String> {
        self.0
            .lock()
            .push(args.iter().map(|argument| argument.to_string()).collect());
        Ok("a".repeat(40))
    }
    fn run_cwd(&self, cwd: &std::path::Path, args: &[&str]) -> Result<String, String> {
        self.run(cwd, args)
    }
}

fn project_developer(harness: &Harness) -> (p256::ecdsa::SigningKey, uuid::Uuid) {
    let key = fresh_device_key();
    let id = uuid::Uuid::new_v4();
    sparkd::store::insert_device(
        &harness.state.database.as_ref().unwrap().lock(),
        &id,
        "project-developer",
        "macos",
        &spki_der(&key),
        &format!("fp-project-{id}"),
        "developer",
    )
    .unwrap();
    (key, id)
}

include!("project_flow/scenarios/project_create_rejects_non_https_sources_before_dispatch.rs");

include!("project_flow/scenarios/project_create_accepts_https_through_the_controlled_runner.rs");

include!("project_flow/scenarios/development_workspaces.rs");

include!("project_flow/scenarios/terminal_apple_interop.rs");

#[tokio::test]
async fn owners_can_prepare_development_once_and_read_its_status() {
    let (harness, addr, key, device) = harness().await;
    let warmed = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let counter = warmed.clone();
    let preparation = Arc::new(
        sparkd::project_api::development_prepare::DevelopmentPreparation::with_harness_warmer(
            Arc::new(move |_| {
                counter.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                Ok(true)
            }),
        ),
    );
    let state = harness
        .state
        .clone()
        .with_development_preparation(preparation);
    let listener = tokio::net::TcpListener::bind(("127.0.0.1", 0))
        .await
        .expect("bind");
    let prepared_addr = listener.local_addr().expect("addr");
    tokio::spawn(async move {
        axum::serve(listener, router(state)).await.expect("serve");
    });
    let _ = addr;
    let client = reqwest::Client::new();

    let (status, body) = signed_json(
        &client,
        prepared_addr,
        &key,
        &device,
        "GET",
        "/api/v1/development/preparation",
        None,
    )
    .await;
    assert_eq!(status, reqwest::StatusCode::OK, "{body}");
    assert_eq!(body["status"], "idle");
    assert_eq!(body["harness_ready"], false);

    let (status, body) = signed_json(
        &client,
        prepared_addr,
        &key,
        &device,
        "POST",
        "/api/v1/development/preparation",
        None,
    )
    .await;
    assert_eq!(status, reqwest::StatusCode::ACCEPTED, "{body}");
    assert_eq!(body["status"], "preparing");

    let deadline = std::time::Instant::now() + Duration::from_secs(10);
    let settled = loop {
        let (_, body) = signed_json(
            &client,
            prepared_addr,
            &key,
            &device,
            "GET",
            "/api/v1/development/preparation",
            None,
        )
        .await;
        if body["status"] != "preparing" {
            break body;
        }
        assert!(
            std::time::Instant::now() < deadline,
            "preparation never settled"
        );
        tokio::time::sleep(Duration::from_millis(50)).await;
    };
    // Without a privileged helper the image cannot be pulled, but the coding agent is cached.
    assert_eq!(settled["status"], "failed", "{settled}");
    assert_eq!(settled["harness_ready"], true);
    assert_eq!(settled["image_ready"], false);
    assert!(
        settled["detail"]
            .as_str()
            .is_some_and(|detail| detail.contains("privileged helper")),
        "{settled}"
    );
    assert_eq!(warmed.load(std::sync::atomic::Ordering::SeqCst), 1);
    assert!(
        harness
            .state
            .config
            .data_dir
            .join("harness-cache/development-requested")
            .is_file()
    );

    // A device that may only observe never reaches the route.
    let (guest_key, guest_id) = {
        let conn = harness.state.database.as_ref().expect("db").lock();
        let guest_key = fresh_device_key();
        let guest_id = uuid::Uuid::new_v4();
        sparkd::store::insert_device(
            &conn,
            &guest_id,
            "observer-device",
            "ios",
            &spki_der(&guest_key),
            &format!("fp-observer-{guest_id}"),
            "observer",
        )
        .expect("seed guest");
        (guest_key, guest_id)
    };
    let (status, _) = signed_json(
        &client,
        prepared_addr,
        &guest_key,
        &guest_id,
        "POST",
        "/api/v1/development/preparation",
        None,
    )
    .await;
    assert_eq!(status, reqwest::StatusCode::FORBIDDEN);
}
