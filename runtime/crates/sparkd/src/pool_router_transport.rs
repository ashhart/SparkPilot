//! Numeric on-link HTTPS, exact leaf pin, SPARK2, and node-authority response proof.
use crate::{
    auth::{self, AuthenticatedRequest},
    crypto::{base64url_encode, sha256_hex},
    pool::{self, PoolError},
    pool_router_contracts::RouterPeerTrust,
    pool_router_identity::{self as identity, RouterKey},
    state::AppState,
};
use axum::{body::Bytes, http::Method};
use futures::{Stream, StreamExt};
use p256::ecdsa::signature::Signer;
use rusqlite::OptionalExtension;
use rustls::{
    DigitallySignedStruct, SignatureScheme,
    client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier},
    pki_types::{CertificateDer, ServerName, UnixTime},
};
use serde_json::Value;
use std::{net::IpAddr, pin::Pin, sync::Arc, time::Duration};
use uuid::Uuid;
fn error() -> PoolError {
    PoolError::Refused("POOL_ROUTER_TRANSPORT_UNVERIFIED")
}
#[derive(Debug)]
struct ExactLeaf {
    fingerprint: String,
}
impl ServerCertVerifier for ExactLeaf {
    fn verify_server_cert(
        &self,
        cert: &CertificateDer<'_>,
        _: &[CertificateDer<'_>],
        _: &ServerName<'_>,
        _: &[u8],
        _: UnixTime,
    ) -> Result<ServerCertVerified, rustls::Error> {
        if sha256_hex(cert.as_ref()) != self.fingerprint {
            return Err(rustls::Error::General("pinned leaf mismatch".into()));
        }
        Ok(ServerCertVerified::assertion())
    }
    fn verify_tls12_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        signature: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls12_signature(
            message,
            cert,
            signature,
            &rustls::crypto::ring::default_provider().signature_verification_algorithms,
        )
    }
    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        signature: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls13_signature(
            message,
            cert,
            signature,
            &rustls::crypto::ring::default_provider().signature_verification_algorithms,
        )
    }
    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        rustls::crypto::ring::default_provider()
            .signature_verification_algorithms
            .supported_schemes()
    }
}
pub async fn validate_route(trust: &RouterPeerTrust) -> Result<reqwest::Url, PoolError> {
    if !pool::valid_digest(&trust.authority_fingerprint)
        || !pool::valid_digest(&trust.tls_certificate_sha256)
    {
        return Err(error());
    }
    let url = reqwest::Url::parse(&trust.endpoint).map_err(|_| error())?;
    if url.scheme() != "https"
        || !url.username().is_empty()
        || url.password().is_some()
        || url.query().is_some()
        || url.fragment().is_some()
        || !matches!(url.path(), "" | "/")
        || url.port() == Some(0)
    {
        return Err(error());
    }
    let ip: IpAddr = url
        .host_str()
        .ok_or_else(error)?
        .trim_matches(['[', ']'])
        .parse()
        .map_err(|_| error())?;
    if !crate::pool_api::direct_physical_route(ip).await {
        return Err(PoolError::Refused("POOL_LOCAL_ROUTE_REQUIRED"));
    }
    Ok(url)
}
fn client(trust: &RouterPeerTrust) -> Result<reqwest::Client, PoolError> {
    let tls = rustls::ClientConfig::builder_with_provider(
        rustls::crypto::ring::default_provider().into(),
    )
    .with_safe_default_protocol_versions()
    .map_err(|_| error())?
    .dangerous()
    .with_custom_certificate_verifier(Arc::new(ExactLeaf {
        fingerprint: trust.tls_certificate_sha256.clone(),
    }))
    .with_no_client_auth();
    reqwest::Client::builder()
        .no_proxy()
        .redirect(reqwest::redirect::Policy::none())
        .use_preconfigured_tls(tls)
        .connect_timeout(Duration::from_secs(3))
        .timeout(Duration::from_secs(120))
        .build()
        .map_err(|_| error())
}
/// Before router grants exist, signed enrollment challenges prove authority while this probe verifies the owner-pinned leaf and node audience.
pub async fn probe_enrollment(trust: &RouterPeerTrust) -> Result<(), PoolError> {
    let mut url = validate_route(trust).await?;
    url.set_path("/api/v1/health");
    let response = client(trust)?
        .get(url)
        .timeout(Duration::from_secs(3))
        .send()
        .await
        .map_err(|_| error())?;
    if !response.status().is_success() {
        return Err(error());
    }
    let value = read_json(response, 16 * 1024).await?;
    if value["node_id"] != trust.node_id.to_string() {
        return Err(error());
    }
    Ok(())
}
pub struct RouterPeerResponse {
    response: reqwest::Response,
}
impl RouterPeerResponse {
    pub fn status(&self) -> axum::http::StatusCode {
        self.response.status()
    }
    pub async fn json(self) -> Result<Value, PoolError> {
        read_json(self.response, 2 * 1024 * 1024).await
    }
    pub fn stream(self) -> Pin<Box<dyn Stream<Item = Result<Bytes, PoolError>> + Send>> {
        Box::pin(futures::stream::unfold(
            (self.response.bytes_stream(), 0usize, false),
            |(mut upstream, mut total, failed)| async move {
                if failed {
                    return None;
                }
                let chunk = upstream.next().await?;
                let result = chunk.map_err(|_| error()).and_then(|chunk| {
                    total = total.saturating_add(chunk.len());
                    if total > 8 * 1024 * 1024 {
                        Err(PoolError::Refused("POOL_ROUTER_RESPONSE_LIMIT"))
                    } else {
                        Ok(chunk)
                    }
                });
                let failed = result.is_err();
                Some((result, (upstream, total, failed)))
            },
        ))
    }
}
async fn read_json(response: reqwest::Response, limit: usize) -> Result<Value, PoolError> {
    let mut stream = response.bytes_stream();
    let mut body = Vec::new();
    while let Some(chunk) = stream.next().await {
        let chunk = chunk.map_err(|_| error())?;
        if body.len().saturating_add(chunk.len()) > limit {
            return Err(PoolError::Refused("POOL_ROUTER_RESPONSE_LIMIT"));
        }
        body.extend_from_slice(&chunk);
    }
    serde_json::from_slice(&body).map_err(|_| error())
}
pub async fn request(
    state: &AppState,
    recipient: Uuid,
    method: Method,
    path: &str,
    body: Bytes,
    idempotency: Option<Uuid>,
) -> Result<RouterPeerResponse, PoolError> {
    if !identity::allowed_route(method.as_str(), path)
        || body.len() > crate::pool_contracts::MAX_REQUEST_BYTES
        || (method == Method::POST && idempotency.is_none())
        || (method == Method::GET && !body.is_empty())
    {
        return Err(PoolError::Refused("POOL_ROUTER_SCOPE_FORBIDDEN"));
    }
    let key = state.router_identity.load()?;
    let (trust, authority) = {
        let conn = pool::database(state)?.lock();
        let row:Option<(String,String,String,String)>=conn.query_row("SELECT trust_json,authority_public_key,principal_id,approved_by_device_id FROM pool_router_peers WHERE node_id=?1 AND principal_id=?2",rusqlite::params![recipient.to_string(),key.principal_id.to_string()],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?,r.get(3)?))).optional()?;
        let Some((trust, authority, principal, owner)) = row else {
            return Err(error());
        };
        if principal != key.principal_id.to_string() {
            return Err(PoolError::Refused("POOL_ROUTER_KEY_CHANGED"));
        }
        pool::eligible_owner(&conn, Uuid::parse_str(&owner).map_err(|_| error())?)?;
        (serde_json::from_str::<RouterPeerTrust>(&trust)?, authority)
    };
    identity::verify_authority_anchor(&authority, &trust.authority_fingerprint)?;
    let mut url = validate_route(&trust).await?;
    url.set_path(path);
    let now = time::OffsetDateTime::now_utc()
        .format(&time::format_description::well_known::Rfc3339)
        .map_err(|_| error())?;
    let auth = AuthenticatedRequest {
        method: method.as_str().into(),
        path_and_query: path.into(),
        timestamp: now,
        nonce: base64url_encode(Uuid::new_v4().as_bytes()),
        content_sha256: sha256_hex(&body),
        device_id: key.principal_id,
        node_id: recipient,
    };
    let builder = signed(
        client(&trust)?.request(method, url),
        &key,
        &auth,
        idempotency,
    )
    .body(body);
    let response = builder.send().await.map_err(|_| error())?;
    let proof = response
        .headers()
        .get(identity::RESPONSE_PROOF)
        .and_then(|v| v.to_str().ok())
        .ok_or_else(error)?;
    identity::verify_response(
        &authority,
        &trust.authority_fingerprint,
        &auth,
        response.status().as_u16(),
        &trust.tls_certificate_sha256,
        proof,
    )?;
    if response.status().is_redirection() {
        return Err(error());
    }
    Ok(RouterPeerResponse { response })
}
fn signed(
    builder: reqwest::RequestBuilder,
    key: &RouterKey,
    request: &AuthenticatedRequest,
    idempotency: Option<Uuid>,
) -> reqwest::RequestBuilder {
    let canonical = auth::canonical(
        &request.method,
        &request.path_and_query,
        &request.timestamp,
        &request.nonce,
        &request.content_sha256,
        &request.device_id,
        &request.node_id,
    );
    let signature: p256::ecdsa::Signature = key.signing.sign(canonical.as_bytes());
    let builder = builder
        .header(auth::HEADER_NODE_ID, request.node_id.to_string())
        .header(auth::HEADER_DEVICE_ID, request.device_id.to_string())
        .header(auth::HEADER_TIMESTAMP, &request.timestamp)
        .header(auth::HEADER_NONCE, &request.nonce)
        .header(auth::HEADER_CONTENT_SHA256, &request.content_sha256)
        .header(
            auth::HEADER_SIGNATURE,
            base64url_encode(&signature.to_bytes()),
        )
        .header("content-type", "application/json");
    if let Some(id) = idempotency {
        builder.header("idempotency-key", id.to_string())
    } else {
        builder
    }
}
