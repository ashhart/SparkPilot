//! Exercise HTTP bootstrap, challenge, claim, signed requests, replay/tamper refusal and revocation.

const SIGNING_NODE_ID: uuid::Uuid = uuid::Uuid::from_u128(2);

use std::sync::Arc;

use axum::body::to_bytes;
use axum::http::{HeaderValue, Method, Request, StatusCode};
use p256::ecdsa::signature::Signer as _;
use p256::pkcs8::EncodePublicKey;
use rand::RngCore;
use serde_json::{Value, json};
use spark_core::identity::{FileIdentityStore, IdentityStore};
use spark_telemetry::FakeSystemMonitor;
use sparkd::auth;
use sparkd::crypto::{base64_encode, base64url_decode, base64url_encode, sha256_hex};
use sparkd::migration;
use sparkd::pairing;
use sparkd::route::router;
use sparkd::state::{AppState, RuntimeConfig};
use tower::ServiceExt;

struct TestPeer {
    state: AppState,
    identity: spark_core::identity::NodeIdentity,
    device_key: p256::ecdsa::SigningKey,
    presence_key: p256::ecdsa::SigningKey,
    device_id: uuid::Uuid,
}

fn fresh_device_key() -> p256::ecdsa::SigningKey {
    // Generate raw P-256 scalar bytes to avoid the rand_core version mismatch with workspace rand.
    loop {
        let mut scalar = [0u8; 32];
        rand::rng().fill_bytes(&mut scalar);
        if let Ok(key) = p256::ecdsa::SigningKey::from_slice(&scalar) {
            return key;
        }
    }
}

fn full_peer() -> TestPeer {
    let dir = tempfile::tempdir().unwrap();
    let mut identity = FileIdentityStore::new(dir.path().join("identity"))
        .load_or_create("pairing-test")
        .expect("identity");
    identity.public.node_id = SIGNING_NODE_ID;

    let mut conn = rusqlite::Connection::open_in_memory().expect("db");
    migration::migrate(&mut conn).expect("migrate");

    let config = RuntimeConfig {
        api_major: 1,
        runtime_version: "0.1.0".to_owned(),
        listen: "127.0.0.1:0".parse().unwrap(),
        node_name: "pairing-test".to_owned(),
        data_dir: dir.path().to_path_buf(),
        advertise: false,
        tls: false,
    };
    let state = AppState::new(
        config,
        identity.clone(),
        Arc::new(FakeSystemMonitor),
        Some(conn),
    );

    TestPeer {
        state,
        identity,
        device_key: fresh_device_key(),
        presence_key: fresh_device_key(),
        device_id: uuid::Uuid::new_v4(),
    }
}

fn spki_der(key: &p256::ecdsa::SigningKey) -> Vec<u8> {
    key.verifying_key()
        .to_public_key_der()
        .expect("spki der")
        .as_bytes()
        .to_vec()
}

/// Standard base64 SPKI as transported by `contentEncoding: base64`.
fn spki_b64(key: &p256::ecdsa::SigningKey) -> String {
    base64_encode(&spki_der(key))
}

fn canonical_point(key: &p256::ecdsa::SigningKey) -> Vec<u8> {
    key.verifying_key()
        .to_encoded_point(false)
        .as_bytes()
        .to_vec()
}

fn presence_key_fingerprint(key: &p256::ecdsa::SigningKey) -> String {
    sha256_hex(&canonical_point(key))
}

/// Build a fully signed request per §58.3.
fn signed_request(
    peer: &TestPeer,
    method: Method,
    path: &str,
    body: &[u8],
    nonce: &str,
    timestamp: &str,
) -> Request<axum::body::Body> {
    let digest = sha256_hex(body);
    let canonical = auth::canonical(
        method.as_str(),
        path,
        timestamp,
        nonce,
        &digest,
        &peer.device_id,
        &SIGNING_NODE_ID,
    );
    let signature: p256::ecdsa::Signature = peer.device_key.sign(canonical.as_bytes());
    let signature_b64 = base64url_encode(&signature.to_bytes());

    let builder = Request::builder()
        .method(method)
        .uri(path)
        .header("idempotency-key", uuid::Uuid::new_v4().to_string())
        .header(auth::HEADER_DEVICE_ID, peer.device_id.to_string())
        .header("x-spark-node-id", SIGNING_NODE_ID.to_string())
        .header(auth::HEADER_TIMESTAMP, timestamp)
        .header(auth::HEADER_NONCE, nonce)
        .header(auth::HEADER_CONTENT_SHA256, digest)
        .header(auth::HEADER_SIGNATURE, signature_b64);

    if body.is_empty() {
        builder.body(axum::body::Body::empty()).unwrap()
    } else {
        builder
            .header("content-type", HeaderValue::from_static("application/json"))
            .body(axum::body::Body::from(body.to_vec()))
            .unwrap()
    }
}

#[allow(clippy::too_many_arguments)]
fn signed_request_with_presence(
    peer: &TestPeer,
    method: Method,
    path: &str,
    presence_path: &str,
    body: &[u8],
    nonce: &str,
    timestamp: &str,
    expires_at: &str,
) -> Request<axum::body::Body> {
    let digest = sha256_hex(body);
    let canonical = spark_contracts::user_presence_canonical(
        method.as_str(),
        presence_path,
        timestamp,
        nonce,
        &digest,
        &peer.device_id,
        expires_at,
        &SIGNING_NODE_ID,
    );
    let signature: p256::ecdsa::Signature = peer.presence_key.sign(canonical.as_bytes());
    let proof = spark_contracts::UserPresenceHeader {
        version: spark_contracts::USER_PRESENCE_PROOF_VERSION,
        expires_at: expires_at.into(),
        signature: base64url_encode(&signature.to_bytes()),
    };
    let encoded = base64url_encode(&serde_json::to_vec(&proof).unwrap());
    let mut request = signed_request(peer, method, path, body, nonce, timestamp);
    request.headers_mut().insert(
        sparkd::user_presence::HEADER_USER_PRESENCE,
        HeaderValue::from_str(&encoded).unwrap(),
    );
    request
}

fn signed_presence_enrollment(
    peer: &TestPeer,
    proposed_key: &p256::ecdsa::SigningKey,
    proof_key: &p256::ecdsa::SigningKey,
) -> Request<axum::body::Body> {
    let path = "/api/v1/devices/self/presence-key";
    let timestamp = rfc3339_now();
    let nonce = fresh_nonce();
    let fingerprint = presence_key_fingerprint(proposed_key);
    let body = serde_json::to_vec(&json!({
        "presence_public_key_spki": spki_b64(proposed_key),
    }))
    .unwrap();
    let content_sha256 = sha256_hex(&body);
    let canonical = spark_contracts::presence_enrollment_canonical(
        "POST",
        path,
        &timestamp,
        &nonce,
        &content_sha256,
        &peer.device_id,
        &fingerprint,
        &SIGNING_NODE_ID,
    );
    let proof: p256::ecdsa::Signature = proof_key.sign(canonical.as_bytes());
    let mut request = signed_request(peer, Method::POST, path, &body, &nonce, &timestamp);
    request.headers_mut().insert(
        sparkd::user_presence::HEADER_PRESENCE_KEY_PROOF,
        HeaderValue::from_str(&base64url_encode(&proof.to_bytes())).unwrap(),
    );
    request
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

async fn send_json(
    peer: &TestPeer,
    method: Method,
    path: &str,
    body: Value,
) -> (StatusCode, Option<Value>) {
    let body_bytes = serde_json::to_vec(&body).unwrap();
    let request = signed_request(
        peer,
        method,
        path,
        &body_bytes,
        &fresh_nonce(),
        &rfc3339_now(),
    );
    let response = router(peer.state.clone()).oneshot(request).await.unwrap();
    let status = response.status();
    let bytes = to_bytes(response.into_body(), 1 << 20).await.unwrap();
    let value = serde_json::from_slice(&bytes).ok();
    (status, value)
}

fn audit_rows(peer: &TestPeer, action: &str) -> Vec<(String, String, String, String, String)> {
    let connection = peer.state.database.as_ref().expect("db").lock();
    let mut statement = connection
        .prepare(
            "SELECT COALESCE(actor_device_id, ''), COALESCE(actor_role, ''),
                    COALESCE(resource, ''), result, details_json
               FROM audit_records
              WHERE action = ?1
              ORDER BY sequence",
        )
        .unwrap();
    statement
        .query_map([action], |row| {
            Ok((
                row.get(0)?,
                row.get(1)?,
                row.get(2)?,
                row.get(3)?,
                row.get(4)?,
            ))
        })
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap()
}

/// Seed the installer issuer and create its first-owner invitation as install-time bootstrap does.
fn bootstrap_owner_invitation(peer: &TestPeer) -> (pairing::InvitationPayload, uuid::Uuid) {
    let conn = peer.state.database.as_ref().expect("db").lock();
    let installer_id = uuid::Uuid::new_v4();
    let installer_key = fresh_device_key();
    let spki = spki_der(&installer_key);
    sparkd::store::insert_installer_device(&conn, &installer_id, &spki)
        .expect("seed installer device");
    let issued = pairing::issue_invitation(
        &conn,
        &peer.identity,
        &installer_id,
        "owner".into(),
        None,
        None,
    )
    .expect("issue owner invitation");

    // Sanity: the row must be loadable afterwards (same connection).
    let reloaded = sparkd::store::load_pending_invitation(&conn, &issued.payload.invitation_id)
        .expect("load pending invitation");
    let flags_now: (Option<String>, Option<String>) = conn
        .query_row(
            "SELECT consumed_at, revoked_at FROM pairing_invitations WHERE id = ?1",
            rusqlite::params![issued.payload.invitation_id.to_string()],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .expect("flags");
    assert!(
        reloaded.is_some(),
        "invitation must be persisted before claiming: {} (flags {flags_now:?})",
        issued.payload.invitation_id
    );

    (issued.payload, installer_id)
}

fn device_challenge_signature(
    claiming_peer: &TestPeer,
    server_node_id: uuid::Uuid,
    challenge_bytes: &[u8],
    invitation_id: &uuid::Uuid,
    presence_key_fingerprint: Option<&str>,
) -> String {
    let material = pairing_claim_material(
        claiming_peer,
        server_node_id,
        challenge_bytes,
        invitation_id,
        presence_key_fingerprint,
    );
    let signature: p256::ecdsa::Signature = claiming_peer.device_key.sign(&material);
    base64url_encode(&signature.to_bytes())
}

fn pairing_claim_material(
    claiming_peer: &TestPeer,
    server_node_id: uuid::Uuid,
    challenge_bytes: &[u8],
    invitation_id: &uuid::Uuid,
    presence_key_fingerprint: Option<&str>,
) -> Vec<u8> {
    if let Some(fingerprint) = presence_key_fingerprint {
        return spark_contracts::pairing_presence_canonical(
            &base64url_encode(challenge_bytes),
            invitation_id,
            &claiming_peer.device_id,
            &server_node_id,
            fingerprint,
        )
        .into_bytes();
    }
    [
        challenge_bytes,
        invitation_id.to_string().as_bytes(),
        claiming_peer.device_id.to_string().as_bytes(),
        server_node_id.to_string().as_bytes(),
    ]
    .concat()
}

async fn pairing_challenge(
    peer: &TestPeer,
    invitation: &pairing::InvitationPayload,
    claiming_peer: &TestPeer,
) -> (uuid::Uuid, Vec<u8>) {
    let (status, challenge) = send_json(
        peer,
        Method::POST,
        "/api/v1/pairing/challenge",
        json!({
            "invitation_id": invitation.invitation_id,
            "device_public_key_spki": spki_b64(&claiming_peer.device_key),
        }),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "challenge accepted");
    let challenge = challenge.expect("challenge response body");
    assert_eq!(
        challenge["authority_fingerprint"].as_str().unwrap(),
        peer.identity.fingerprint()
    );
    (
        serde_json::from_value(challenge["challenge_id"].clone()).unwrap(),
        base64url_decode(challenge["challenge"].as_str().unwrap()).unwrap(),
    )
}

async fn run_claim(
    peer: &TestPeer,
    invitation: &pairing::InvitationPayload,
    claiming_peer: &TestPeer,
    device_name: &str,
    platform: &str,
) -> (StatusCode, Option<Value>) {
    run_claim_with_presence_key(peer, invitation, claiming_peer, device_name, platform, true).await
}

async fn run_claim_with_presence_key(
    peer: &TestPeer,
    invitation: &pairing::InvitationPayload,
    claiming_peer: &TestPeer,
    device_name: &str,
    platform: &str,
    register_presence_key: bool,
) -> (StatusCode, Option<Value>) {
    let (challenge_id, challenge_bytes) = pairing_challenge(peer, invitation, claiming_peer).await;
    let presence_fingerprint =
        register_presence_key.then(|| presence_key_fingerprint(&claiming_peer.presence_key));
    let claim_sig = device_challenge_signature(
        claiming_peer,
        peer.identity.node_id(),
        &challenge_bytes,
        &invitation.invitation_id,
        presence_fingerprint.as_deref(),
    );

    let mut body = json!({
        "invitation": serde_json::to_value(invitation).unwrap(),
        "challenge_id": challenge_id,
        "device_id": claiming_peer.device_id,
        "device_name": device_name,
        "platform": platform,
        "device_public_key_spki": spki_b64(&claiming_peer.device_key),
        "challenge_signature": claim_sig,
    });
    if register_presence_key {
        body["presence_public_key_spki"] = json!(spki_b64(&claiming_peer.presence_key));
        let material = pairing_claim_material(
            claiming_peer,
            peer.identity.node_id(),
            &challenge_bytes,
            &invitation.invitation_id,
            presence_fingerprint.as_deref(),
        );
        let signature: p256::ecdsa::Signature = claiming_peer.presence_key.sign(&material);
        body["presence_key_signature"] = json!(base64url_encode(&signature.to_bytes()));
    }
    send_json(peer, Method::POST, "/api/v1/pairing/claim", body).await
}

include!("pairing_flow/scenarios/full_pair_and_signed_request_flow.rs");
include!(
    "pairing_flow/scenarios/a_new_grant_is_announced_to_administrators_without_key_material.rs"
);

include!(
    "pairing_flow/scenarios/bound_batch_claims_are_independent_idempotent_and_recipient_locked.rs"
);

include!("pairing_flow/scenarios/bound_invitation_refuses_substituted_device_id_before_grant.rs");

include!(
    "pairing_flow/scenarios/public_claim_refusals_require_genuine_live_pairing_state_before_audit.rs"
);

include!("pairing_flow/scenarios/replay_and_tampering_are_rejected.rs");

include!("pairing_flow/scenarios/concurrent_identical_signed_requests_admit_exactly_one_nonce.rs");

include!("pairing_flow/scenarios/nonce_storage_failure_fails_authentication_closed.rs");

include!("pairing_flow/scenarios/revocation_terminates_access.rs");

include!(
    "pairing_flow/scenarios/six_digit_join_code_returns_the_signed_package_and_expires_with_the_invitation.rs"
);

include!("pairing_flow/scenarios/a_device_paired_before_presence_keys_cannot_revoke.rs");

include!("pairing_flow/scenarios/legacy_device_can_enroll_presence_key_once_and_then_revoke.rs");

include!("pairing_flow/scenarios/pairing_claim_rolls_back_when_the_audit_chain_is_unavailable.rs");

include!(
    "pairing_flow/scenarios/pairing_invitation_rolls_back_when_the_audit_chain_is_unavailable.rs"
);

include!(
    "pairing_flow/scenarios/presence_enrollment_rolls_back_when_the_audit_chain_is_unavailable.rs"
);

include!("pairing_flow/scenarios/grants_never_expose_private_material.rs");

include!("pairing_flow/scenarios/the_installer_grant_is_revoked_once_the_owner_claims.rs");

include!("pairing_flow/scenarios/a_claim_may_not_substitute_a_different_device_key.rs");

include!("pairing_flow/scenarios/pairing_presence_registration_is_bound_and_proves_possession.rs");

include!("pairing_flow/scenarios/alternate_spki_encoding_cannot_hide_reuse_of_the_device_key.rs");

include!(
    "pairing_flow/scenarios/administrator_invitations_require_fresh_presence_for_every_retrieval.rs"
);

include!(
    "pairing_flow/scenarios/administrator_cannot_escalate_or_revoke_owner_before_presence_prompt.rs"
);

include!("pairing_flow/scenarios/authenticated_join_code_exchange.rs");
