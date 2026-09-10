//! Two independent real TLS nodes, owner presence, service signing and pins.
use axum::http::{Method, StatusCode};
use futures::StreamExt;
use p256::{ecdsa::signature::Signer, pkcs8::EncodePublicKey};
use serde_json::{Value, json};
use spark_core::identity::{FileIdentityStore, IdentityStore};
use sparkd::{
    auth,
    crypto::{base64url_encode, sha256_hex},
    pool_router_contracts::*,
    pool_router_transport as transport,
    route::{router, socket_service},
    state::{AppState, RuntimeConfig},
};
use std::{
    net::SocketAddr,
    sync::{
        Arc,
        atomic::{AtomicU8, AtomicUsize, Ordering},
    },
    time::Duration,
};
use tower::ServiceExt;
use uuid::Uuid;
const BASE: &str = "/api/v1/inference";
struct Node {
    state: AppState,
    owner_id: Uuid,
    owner_key: p256::ecdsa::SigningKey,
    presence: p256::ecdsa::SigningKey,
    client: reqwest::Client,
    address: SocketAddr,
    server: axum_server::Handle<SocketAddr>,
    task: tokio::task::JoinHandle<()>,
    response_fault: Arc<AtomicU8>,
    pool_requests: Arc<AtomicUsize>,
    _dir: tempfile::TempDir,
}
async fn node() -> Node {
    node_with_model(false).await
}
struct Roomy;
impl spark_telemetry::SystemMonitor for Roomy {
    fn system(&self) -> spark_telemetry::SystemSnapshot {
        let mut snapshot =
            spark_telemetry::SystemMonitor::system(&spark_telemetry::FakeSystemMonitor);
        snapshot.unified_memory_total_bytes = 240 << 30;
        snapshot.unified_memory_available_bytes = 200 << 30;
        snapshot
    }
    fn inference(&self) -> spark_telemetry::InferenceSnapshot {
        Default::default()
    }
}
async fn node_with_model(with_model: bool) -> Node {
    let dir = tempfile::tempdir().unwrap();
    let identity = FileIdentityStore::new(dir.path().join("identity"))
        .load_or_create("router-test")
        .unwrap();
    let tls = sparkd::tls::load_or_create(&dir.path().join("tls")).unwrap();
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    listener.set_nonblocking(true).unwrap();
    let address = listener.local_addr().unwrap();
    let mut conn = rusqlite::Connection::open(dir.path().join("state.sqlite")).unwrap();
    sparkd::migration::migrate_with_recovery_point(&mut conn, &dir.path().join("state.sqlite"))
        .unwrap();
    let config = RuntimeConfig {
        api_major: 1,
        runtime_version: "0.1.0".into(),
        listen: address,
        node_name: "router-test".into(),
        data_dir: dir.path().into(),
        advertise: false,
        tls: true,
    };
    let mut state = AppState::new(config, identity, Arc::new(Roomy), None)
        .with_database(Arc::new(parking_lot::Mutex::new(conn)));
    state.tls_fingerprint = Some(tls.fingerprint.clone());
    let owner_id = Uuid::new_v4();
    let owner_key = p256::ecdsa::SigningKey::random(&mut p256::elliptic_curve::rand_core::OsRng);
    let presence = p256::ecdsa::SigningKey::random(&mut p256::elliptic_curve::rand_core::OsRng);
    let key = owner_key.verifying_key().to_public_key_der().unwrap();
    let pkey = presence.verifying_key().to_public_key_der().unwrap();
    sparkd::store::insert_device_with_presence_key(
        &state.database.as_ref().unwrap().lock(),
        &owner_id,
        "Owner",
        "ios",
        key.as_bytes(),
        &sha256_hex(key.as_bytes()),
        "owner",
        Some((pkey.as_bytes(), &sha256_hex(pkey.as_bytes()))),
    )
    .unwrap();
    if with_model {
        let mut recipe = spark_models::recipe::fixture::RecipeFixture::example();
        recipe.profiles[0].max_sequences = 1;
        let signing = ed25519_dalek::SigningKey::from_bytes(&[9; 32]);
        recipe.signature.value = base64url_encode(
            &signing
                .sign(&recipe.canonical_without_signature().unwrap())
                .to_bytes(),
        );
        {
            let conn = state.database.as_ref().unwrap().lock();
            sparkd::store::upsert_catalogue_model(&conn, &recipe).unwrap();
            sparkd::store::mark_model_installed(&conn, recipe.id(), 1 << 30).unwrap();
        }
        state = state
            .with_models(Arc::new(sparkd::models::ModelInventory {
                recipes: vec![recipe.clone()],
                allow_unverified_import: false,
            }))
            .with_disk_reserve(0);
        let backend = Arc::new(sparkd::engine_backend::MockVllmBackend::new());
        backend.set_force_fallback_port(true);
        let manager = Arc::new(
            sparkd::engine::EngineManager::new(
                backend,
                state.jobs.clone(),
                state.events.clone(),
                state.identity.node_id().to_string(),
                Arc::new(Roomy),
                state.database.as_ref().unwrap().clone(),
                dir.path().join("models"),
                Duration::from_millis(50),
                None,
            )
            .with_model_policy(0, Duration::from_secs(10), Duration::ZERO),
        );
        state = state.with_engine(manager.clone());
        let op = state
            .jobs
            .create(
                &state.database.as_ref().unwrap().lock(),
                "model.load",
                owner_id,
                Some(recipe.id()),
                "{}",
            )
            .unwrap();
        manager
            .spawn_load(op, &recipe, &recipe.profiles[0].id, false)
            .unwrap();
        tokio::time::timeout(Duration::from_secs(15), async {
            while manager
                .view()
                .is_none_or(|v| v.state != sparkd::engine::EngineState::Ready)
            {
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .unwrap();
    }
    let client = reqwest::Client::builder()
        .no_proxy()
        .redirect(reqwest::redirect::Policy::none())
        .add_root_certificate(reqwest::Certificate::from_der(&tls.certificate_der).unwrap())
        .resolve("localhost", address)
        .timeout(Duration::from_secs(5))
        .build()
        .unwrap();
    let config = axum_server::tls_rustls::RustlsConfig::from_config(tls.into_rustls_config());
    let handle = axum_server::Handle::new();
    let handle2 = handle.clone();
    let response_fault = Arc::new(AtomicU8::new(0));
    let pool_requests = Arc::new(AtomicUsize::new(0));
    let fault = response_fault.clone();
    let requests = pool_requests.clone();
    let app = router(state.clone()).layer(axum::middleware::from_fn(
        move |request: axum::extract::Request, next: axum::middleware::Next| {
            let fault = fault.clone();
            let requests = requests.clone();
            async move {
                let pools = request.uri().path() == "/api/v1/inference/pools";
                if pools {
                    requests.fetch_add(1, Ordering::SeqCst);
                }
                let mut response = next.run(request).await;
                if pools {
                    match fault.load(Ordering::SeqCst) {
                        1 => {
                            response
                                .headers_mut()
                                .remove(sparkd::pool_router_identity::RESPONSE_PROOF);
                        }
                        2 => {
                            response.headers_mut().insert(
                                sparkd::pool_router_identity::RESPONSE_PROOF,
                                "invalid".parse().unwrap(),
                            );
                        }
                        3 => {
                            *response.status_mut() = StatusCode::FORBIDDEN;
                        }
                        4 => {
                            *response.status_mut() = StatusCode::TEMPORARY_REDIRECT;
                            response.headers_mut().insert(
                                "location",
                                format!("https://{address}/api/v1/inference/pools?redirected=1")
                                    .parse()
                                    .unwrap(),
                            );
                        }
                        5 => {
                            *response.body_mut() =
                                axum::body::Body::from(vec![b' '; 2 * 1024 * 1024 + 1]);
                        }
                        6 => {
                            *response.body_mut() =
                                axum::body::Body::from(vec![b' '; 8 * 1024 * 1024 + 1]);
                        }
                        _ => {}
                    }
                }
                response
            }
        },
    ));
    let task = tokio::spawn(async move {
        axum_server::from_tcp_rustls(listener, config)
            .unwrap()
            .handle(handle2)
            .serve(socket_service(app))
            .await
            .unwrap();
    });
    assert!(handle.listening().await.is_some());
    Node {
        state,
        owner_id,
        owner_key,
        presence,
        client,
        address,
        server: handle,
        task,
        response_fault,
        pool_requests,
        _dir: dir,
    }
}
impl Node {
    fn trust(&self) -> RouterPeerTrust {
        RouterPeerTrust {
            node_id: self.state.identity.node_id(),
            authority_fingerprint: self.state.identity.public.authority_fingerprint.clone(),
            tls_certificate_sha256: self.state.tls_fingerprint.clone().unwrap(),
            endpoint: format!("https://{}", self.address),
        }
    }
    async fn call(
        &self,
        method: &str,
        path: &str,
        value: Option<&Value>,
        key: Option<Uuid>,
        presence: bool,
    ) -> (StatusCode, Value) {
        let body = value
            .map(|v| serde_json::to_vec(v).unwrap())
            .unwrap_or_default();
        let headers = sign_headers(
            &self.state,
            self.owner_id,
            &self.owner_key,
            (method, path),
            &body,
            key,
            if presence { Some(&self.presence) } else { None },
        );
        let response = self
            .client
            .request(
                method.parse::<Method>().unwrap(),
                format!("https://localhost:{}{path}", self.address.port()),
            )
            .headers(headers)
            .body(body)
            .send()
            .await
            .unwrap();
        let status = response.status();
        let body = response.bytes().await.unwrap();
        (
            status,
            serde_json::from_slice(&body)
                .unwrap_or_else(|_| json!({"body":String::from_utf8_lossy(&body)})),
        )
    }
    async fn post(&self, path: &str, value: &Value, presence: bool) -> (StatusCode, Value) {
        self.call("POST", path, Some(value), Some(Uuid::new_v4()), presence)
            .await
    }
    async fn stop(mut self) {
        self.server.graceful_shutdown(Some(Duration::from_secs(1)));
        (&mut self.task).await.unwrap();
        tokio::task::spawn_blocking(move || drop(self))
            .await
            .unwrap();
    }
}
fn sign_headers(
    state: &AppState,
    id: Uuid,
    key: &p256::ecdsa::SigningKey,
    request: (&str, &str),
    body: &[u8],
    idempotency: Option<Uuid>,
    presence: Option<&p256::ecdsa::SigningKey>,
) -> reqwest::header::HeaderMap {
    let (method, path) = request;
    let timestamp = time::OffsetDateTime::now_utc()
        .format(&time::format_description::well_known::Rfc3339)
        .unwrap();
    let nonce = base64url_encode(Uuid::new_v4().as_bytes());
    let hash = sha256_hex(body);
    let node = state.identity.node_id();
    let signature: p256::ecdsa::Signature =
        key.sign(auth::canonical(method, path, &timestamp, &nonce, &hash, &id, &node).as_bytes());
    let mut headers = reqwest::header::HeaderMap::new();
    for (name, value) in [
        (auth::HEADER_DEVICE_ID, id.to_string()),
        (auth::HEADER_NODE_ID, node.to_string()),
        (auth::HEADER_TIMESTAMP, timestamp.clone()),
        (auth::HEADER_NONCE, nonce.clone()),
        (auth::HEADER_CONTENT_SHA256, hash.clone()),
        (
            auth::HEADER_SIGNATURE,
            base64url_encode(&signature.to_bytes()),
        ),
        ("content-type", "application/json".into()),
    ] {
        headers.insert(name, value.parse().unwrap());
    }
    if let Some(key) = idempotency {
        headers.insert("idempotency-key", key.to_string().parse().unwrap());
    }
    if let Some(presence) = presence {
        let expires_at = (time::OffsetDateTime::now_utc() + time::Duration::seconds(45))
            .format(&time::format_description::well_known::Rfc3339)
            .unwrap();
        let signature: p256::ecdsa::Signature = presence.sign(
            spark_contracts::user_presence_canonical(
                method,
                path,
                &timestamp,
                &nonce,
                &hash,
                &id,
                &expires_at,
                &node,
            )
            .as_bytes(),
        );
        let proof = spark_contracts::UserPresenceHeader {
            version: spark_contracts::USER_PRESENCE_PROOF_VERSION,
            expires_at,
            signature: base64url_encode(&signature.to_bytes()),
        };
        headers.insert(
            sparkd::user_presence::HEADER_USER_PRESENCE,
            base64url_encode(&serde_json::to_vec(&proof).unwrap())
                .parse()
                .unwrap(),
        );
    }
    headers
}
async fn prepare(source: &Node) -> Value {
    let (s, doc) = source
        .post(&format!("{BASE}/router-identity"), &json!({}), true)
        .await;
    assert_eq!(s, StatusCode::OK, "{doc}");
    doc
}
async fn challenge(source: &Node, destination: &Node, identity: &Value) -> Value {
    let(s,c)=destination.post(&format!("{BASE}/router-enrollments/challenge"),&json!({"identity":identity,"expected_router_node_id":source.state.identity.node_id(),"expected_router_authority_fingerprint":source.state.identity.public.authority_fingerprint,"display_name":"Local router"}),false).await;
    assert_eq!(s, StatusCode::OK, "{c}");
    c
}
async fn enroll(source: &Node, destination: &Node) -> Value {
    let identity = prepare(source).await;
    let challenge = challenge(source, destination, &identity).await;
    let (s, proof) = source
        .post(
            &format!("{BASE}/router-identity/proof"),
            &json!({"challenge":challenge,"recipient":destination.trust()}),
            true,
        )
        .await;
    assert_eq!(s, StatusCode::OK, "{proof}");
    let (s, receipt) = destination
        .post(
            &format!(
                "{BASE}/router-enrollments/{}/apply",
                challenge["challenge_id"].as_str().unwrap()
            ),
            &proof,
            true,
        )
        .await;
    assert_eq!(s, StatusCode::OK, "{receipt}");
    receipt
}
fn private_test_key(source: &Node) -> (Uuid, p256::ecdsa::SigningKey) {
    let path = source
        .state
        .config
        .data_dir
        .join("router-identity/request-key.json");
    let doc: Value = serde_json::from_slice(&std::fs::read(path).unwrap()).unwrap();
    let seed = sparkd::crypto::base64url_decode(doc["seed"].as_str().unwrap()).unwrap();
    (
        Uuid::parse_str(doc["principal_id"].as_str().unwrap()).unwrap(),
        p256::ecdsa::SigningKey::from_slice(&seed).unwrap(),
    )
}
async fn raw_router(
    source: &Node,
    destination: &Node,
    method: &str,
    path: &str,
    body: &Value,
) -> (StatusCode, Value) {
    let (id, key) = private_test_key(source);
    let bytes = serde_json::to_vec(body).unwrap();
    let headers = sign_headers(
        &destination.state,
        id,
        &key,
        (method, path),
        &bytes,
        Some(Uuid::new_v4()),
        None,
    );
    let response = destination
        .client
        .request(
            method.parse::<Method>().unwrap(),
            format!("https://localhost:{}{path}", destination.address.port()),
        )
        .headers(headers)
        .body(bytes)
        .send()
        .await
        .unwrap();
    let status = response.status();
    (status, response.json().await.unwrap())
}

include!(
    "pool_router_identity_flow/scenarios/two_tls_nodes_enroll_a_distinct_restricted_router_and_verify_responses.rs"
);
include!(
    "pool_router_identity_flow/scenarios/self_signed_descriptors_and_wrong_destination_anchors_cannot_enroll.rs"
);
include!(
    "pool_router_identity_flow/scenarios/fresh_presence_exact_receipts_and_single_use_possession_are_enforced.rs"
);
include!(
    "pool_router_identity_flow/scenarios/nonce_replay_wrong_recipient_and_revocation_fail_closed.rs"
);
include!(
    "pool_router_identity_flow/scenarios/explicit_key_rotation_requires_reenrollment_and_retires_old_principal.rs"
);
include!(
    "pool_router_identity_flow/scenarios/wrong_leaf_authority_and_nonlocal_routes_never_receive_a_request.rs"
);

include!(
    "pool_router_identity_flow/scenarios/file_rotation_followed_by_database_failure_never_rotates_twice.rs"
);
include!(
    "pool_router_identity_flow/scenarios/key_storage_rejects_symlink_permissions_oversize_and_survives_restart.rs"
);
include!(
    "pool_router_identity_flow/scenarios/challenge_expiry_and_bound_recipient_reject_cross_node_proofs.rs"
);

include!(
    "pool_router_identity_flow/scenarios/transport_checks_response_authority_status_redirects_and_body_bounds.rs"
);

include!(
    "pool_router_identity_flow/scenarios/service_principal_uses_only_its_owner_granted_deployment_and_revocation_cancels_leases.rs"
);
