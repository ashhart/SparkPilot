//! Signed, terminal node endpoints. These never forward a request to a peer.
use crate::{
    auth::{AccessAuthentication, AuthenticatedRequest, Principal},
    capability::{Capability, Presence},
    idempotency::IdempotencyRequest,
    pool::{self, PoolError, PoolService},
    pool_contracts::*,
    state::AppState,
};
use axum::{
    Extension, Json,
    body::{Body, Bytes},
    extract::{ConnectInfo, Path, State},
    http::{HeaderMap, StatusCode},
    response::{IntoResponse, Response},
};
use futures::StreamExt;
use rusqlite::TransactionBehavior;
use serde_json::{Value, json};
use std::{
    net::{IpAddr, SocketAddr},
    time::Duration,
};
use uuid::Uuid;

type ApiError = (StatusCode, Json<Value>);
type ApiResult = Result<Json<Value>, ApiError>;

fn read_authority(state: &AppState, principal: &Principal) -> Result<(), ApiError> {
    state
        .require(principal, Capability::InferencePoolRoute)
        .resource("inference.pools")
        .check()
}
fn owner(principal: &Principal) -> Result<(), ApiError> {
    if principal.role != "owner" {
        return Err(PoolError::Refused("POOL_ROLE_FORBIDDEN").envelope());
    }
    Ok(())
}
async fn local_route(
    principal: &Principal,
    peer: Option<Extension<ConnectInfo<SocketAddr>>>,
) -> Result<(), ApiError> {
    let Some(Extension(ConnectInfo(peer))) = peer else {
        return Err(PoolError::Refused("POOL_LOCAL_ROUTE_REQUIRED").envelope());
    };
    if principal.access_authentication != AccessAuthentication::DeviceSignature
        || !direct_physical_route(peer.ip()).await
    {
        return Err(PoolError::Refused("POOL_LOCAL_ROUTE_REQUIRED").envelope());
    }
    Ok(())
}

pub(crate) async fn direct_physical_route(peer: IpAddr) -> bool {
    if peer.is_loopback() {
        return true;
    }
    // Require kernel evidence of an on-link physical route; RFC1918/ULA addresses alone cannot distinguish overlays.
    if !cfg!(target_os = "linux") {
        return false;
    }
    let executable = ["/usr/sbin/ip", "/sbin/ip", "/usr/bin/ip", "/bin/ip"]
        .into_iter()
        .find(|p| std::path::Path::new(p).is_file());
    let Some(executable) = executable else {
        return false;
    };
    let output = tokio::time::timeout(
        Duration::from_millis(500),
        tokio::process::Command::new(executable)
            .args(["-j", "route", "get", &peer.to_string()])
            .kill_on_drop(true)
            .output(),
    )
    .await;
    let Ok(Ok(output)) = output else {
        return false;
    };
    if !output.status.success() || output.stdout.len() > 8192 {
        return false;
    }
    physical_route_document(&output.stdout, std::path::Path::new("/sys/class/net"))
}

fn physical_route_document(bytes: &[u8], interfaces: &std::path::Path) -> bool {
    let Ok(Value::Array(routes)) = serde_json::from_slice::<Value>(bytes) else {
        return false;
    };
    if routes.len() != 1 {
        return false;
    }
    let route = &routes[0];
    if route.get("gateway").is_some()
        || route.get("via").is_some()
        || route.get("nexthops").is_some()
        || route.get("type").is_some_and(|v| v != "unicast")
    {
        return false;
    }
    let Some(name) = route["dev"].as_str() else {
        return false;
    };
    if name.is_empty()
        || name.len() > 15
        || !name
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"_-.:".contains(&b))
    {
        return false;
    }
    let path = interfaces.join(name);
    path.join("device").exists()
        && std::fs::read_to_string(path.join("type")).is_ok_and(|v| v.trim() == "1")
        && std::fs::read_to_string(path.join("operstate")).is_ok_and(|v| v.trim() == "up")
}

/// Require fresh distinct presence keys for authority changes, while exact durable retries reuse the accepted gesture.
pub(crate) fn mutate(
    state: &AppState,
    principal: &Principal,
    auth: &AuthenticatedRequest,
    headers: &HeaderMap,
    key: &IdempotencyRequest,
    apply: impl FnOnce(&rusqlite::Connection) -> Result<Value, PoolError>,
) -> ApiResult {
    owner(principal)?;
    state.pools.prepare(state).map_err(PoolError::envelope)?;
    let db = pool::database(state).map_err(PoolError::envelope)?;
    {
        let conn = db.lock();
        pool::eligible_owner(&conn, principal.device_id).map_err(PoolError::envelope)?;
        if let Some(value) = pool::lookup_mutation(&conn, key).map_err(PoolError::envelope)? {
            return Ok(Json(value));
        }
    }
    let presence_key =
        crate::store::load_presence_key_by_device_id(&db.lock(), &principal.device_id)
            .map_err(|_| PoolError::Refused("POOL_STORAGE_UNAVAILABLE").envelope())?;
    crate::user_presence::verify(
        headers.get(crate::user_presence::HEADER_USER_PRESENCE),
        presence_key.as_deref(),
        auth,
        state.clock.now(),
    )
    .map_err(|e| {
        (
            StatusCode::FORBIDDEN,
            Json(json!({"error":{"code":e.code(),"message":"Fresh owner presence is required"}})),
        )
    })?;
    state
        .require(principal, Capability::OwnershipManage)
        .resource("inference.pools")
        .check_with_verified_presence(Presence::Fresh)?;
    let mut conn = db.lock();
    let tx = conn
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .map_err(PoolError::from)
        .map_err(PoolError::envelope)?;
    pool::eligible_owner(&tx, principal.device_id).map_err(PoolError::envelope)?;
    if let Some(value) = pool::lookup_mutation(&tx, key).map_err(PoolError::envelope)? {
        return Ok(Json(value));
    }
    let value = apply(&tx).map_err(PoolError::envelope)?;
    pool::store_mutation(&tx, key, &value, state.clock.now().unix_timestamp())
        .map_err(PoolError::envelope)?;
    tx.commit()
        .map_err(PoolError::from)
        .map_err(PoolError::envelope)?;
    Ok(Json(value))
}

pub async fn list(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
) -> ApiResult {
    read_authority(&state, &principal)?;
    state.pools.prepare(&state).map_err(PoolError::envelope)?;
    let conn = pool::database(&state).map_err(PoolError::envelope)?.lock();
    let mut stmt = conn
        .prepare("SELECT policy_json FROM inference_pool_policies ORDER BY pool_id LIMIT 16")
        .map_err(PoolError::from)
        .map_err(PoolError::envelope)?;
    let raw = stmt
        .query_map([], |r| r.get::<_, String>(0))
        .map_err(PoolError::from)
        .map_err(PoolError::envelope)?;
    let mut values = Vec::new();
    for row in raw {
        let p: InferencePoolPolicy =
            serde_json::from_str(&row.map_err(PoolError::from).map_err(PoolError::envelope)?)
                .map_err(PoolError::from)
                .map_err(PoolError::envelope)?;
        if principal.is_admin()
            || p.caller_device_ids.contains(&principal.device_id)
            || p.router_device_ids.contains(&principal.device_id)
        {
            values.push(p);
        }
    }
    Ok(Json(json!({"pools":values})))
}
pub async fn preview(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    key: IdempotencyRequest,
    Json(request): Json<PoolPolicyPreviewRequest>,
) -> ApiResult {
    owner(&principal)?;
    read_authority(&state, &principal)?;
    let value = state
        .pools
        .preview(&state, principal.device_id, request, &key)
        .map_err(PoolError::envelope)?;
    Ok(Json(
        serde_json::to_value(value)
            .map_err(PoolError::from)
            .map_err(PoolError::envelope)?,
    ))
}
pub async fn apply(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    Extension(auth): Extension<AuthenticatedRequest>,
    key: IdempotencyRequest,
    headers: HeaderMap,
    Json(request): Json<ApplyPoolPolicyRequest>,
) -> ApiResult {
    mutate(&state, &principal, &auth, &headers, &key, |conn| {
        PoolService::apply(conn, &state, principal.device_id, request.preview_id)
    })
}
pub async fn grant(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    Extension(auth): Extension<AuthenticatedRequest>,
    key: IdempotencyRequest,
    headers: HeaderMap,
    Json(request): Json<CreateRouterGrantRequest>,
) -> ApiResult {
    mutate(&state, &principal, &auth, &headers, &key, |conn| {
        PoolService::create_grant(conn, &state, principal.device_id, request)
    })
}
pub async fn revoke(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    Extension(auth): Extension<AuthenticatedRequest>,
    key: IdempotencyRequest,
    Path(id): Path<Uuid>,
    headers: HeaderMap,
) -> ApiResult {
    mutate(&state, &principal, &auth, &headers, &key, |conn| {
        PoolService::revoke(conn, id)
    })
}
pub async fn capabilities(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
) -> ApiResult {
    read_authority(&state, &principal)?;
    state.pools.prepare(&state).map_err(PoolError::envelope)?;
    let mut snapshot = NodeCapabilitySnapshot {
        protocol_version: PROTOCOL_VERSION,
        node_id: state.identity.node_id(),
        generation: state.pools.generation,
        observed_at: state.clock.now().unix_timestamp(),
        valid_for_milliseconds: 5000,
        deployments: vec![],
        active_reservations: 0,
        capacity_available: false,
        exclusion_codes: vec![],
    };
    let granted = if principal.role == crate::pool_router_identity::ROLE {
        let conn = pool::database(&state).map_err(PoolError::envelope)?.lock();
        Some(
            crate::pool_router_identity::granted_deployments(
                &conn,
                principal.device_id,
                state.clock.now().unix_timestamp(),
            )
            .map_err(PoolError::envelope)?,
        )
    } else {
        None
    };
    if granted.as_ref().is_some_and(|ids| ids.is_empty()) {
        snapshot.exclusion_codes.push("POOL_GRANT_REQUIRED".into());
        return Ok(Json(
            serde_json::to_value(snapshot)
                .map_err(PoolError::from)
                .map_err(PoolError::envelope)?,
        ));
    }
    let result = state
        .engine
        .manager
        .as_ref()
        .ok_or(PoolError::Refused("POOL_ENGINE_UNAVAILABLE"))
        .and_then(|manager| {
            manager.with_pool_admission(|instance, direct| {
                let d = pool::deployment(instance, &state.config.runtime_version)?;
                if granted.as_ref().is_some_and(|ids| !ids.contains(&d.deployment_id)) { return Err(PoolError::Refused("POOL_DEPLOYMENT_NOT_GRANTED")); }
                let conn = pool::database(&state)?.lock();
                let charged = pool::engine_capacity_charge(&conn)?.unwrap_or(0);
                snapshot.active_reservations = if granted.is_some() {
                    conn.query_row("SELECT count(*) FROM inference_reservations WHERE router_device_id=?1 AND capacity_released=0 AND state IN ('reserved','accepted','cancel_requested','outcome_unknown')", [principal.device_id.to_string()], |r|r.get(0))?
                } else { charged };
                let quarantined: bool = conn.query_row("SELECT EXISTS(SELECT 1 FROM inference_reservations WHERE state='outcome_unknown' AND capacity_released=0)", [], |r| r.get(0))?;
                if quarantined { snapshot.exclusion_codes.push("POOL_OUTCOME_QUARANTINED".into()); }
                snapshot.capacity_available = charged.saturating_add(direct) < d.max_sequences
                    && pool::check_resource_state(&state, instance).is_ok();
                snapshot.deployments.push(d);
                Ok(())
            })
        });
    if let Err(error) = result {
        snapshot.exclusion_codes.push(match error {
            PoolError::Refused(code) => code.to_owned(),
            PoolError::Engine(e) => e.code().to_owned(),
            _ => "POOL_STORAGE_UNAVAILABLE".into(),
        });
    }
    Ok(Json(
        serde_json::to_value(snapshot)
            .map_err(PoolError::from)
            .map_err(PoolError::envelope)?,
    ))
}
pub async fn reserve(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    peer: Option<Extension<ConnectInfo<SocketAddr>>>,
    key: IdempotencyRequest,
    Json(request): Json<ReserveInferenceRequest>,
) -> Result<(StatusCode, Json<AdmissionReservation>), ApiError> {
    read_authority(&state, &principal)?;
    local_route(&principal, peer).await?;
    Ok((
        StatusCode::CREATED,
        Json(
            state
                .pools
                .reserve(&state, &principal, &key, request)
                .map_err(PoolError::envelope)?,
        ),
    ))
}
pub async fn status(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    Path(id): Path<Uuid>,
) -> Result<Json<AdmissionReservation>, ApiError> {
    read_authority(&state, &principal)?;
    Ok(Json(
        state
            .pools
            .status(&state, &principal, id, false, None)
            .map_err(PoolError::envelope)?,
    ))
}
pub async fn cancel(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    Path(id): Path<Uuid>,
    key: IdempotencyRequest,
) -> Result<Json<AdmissionReservation>, ApiError> {
    read_authority(&state, &principal)?;
    let result = state
        .pools
        .status(&state, &principal, id, true, Some(&key))
        .map_err(PoolError::envelope)?;
    Ok(Json(result))
}

pub async fn execute(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    peer: Option<Extension<ConnectInfo<SocketAddr>>>,
    Path(id): Path<Uuid>,
    key: IdempotencyRequest,
    body: Bytes,
) -> Result<Response, ApiError> {
    read_authority(&state, &principal)?;
    local_route(&principal, peer).await?;
    state.pools.prepare(&state).map_err(PoolError::envelope)?;
    if body.len() > MAX_REQUEST_BYTES {
        return Err(PoolError::Refused("POOL_REQUEST_INVALID").envelope());
    }
    let request = crate::engine_api::parse_chat(&body)?;
    let streaming = request.stream;
    let manager = state
        .engine
        .manager
        .as_ref()
        .ok_or_else(|| PoolError::Refused("POOL_ENGINE_UNAVAILABLE").envelope())?;
    let (reservation, ticket, upstream) = manager
        .begin_pool_request(|instance| {
            state
                .pools
                .accept(&state, &principal, &key, id, &body, instance)
        })
        .map_err(PoolError::envelope)?;
    let upstream_body = request.upstream_body(&upstream.served_name)?;
    let (tx, rx) = tokio::sync::mpsc::channel::<Result<Bytes, std::io::Error>>(4);
    let failure_tx = tx.clone();
    let (head_tx, head_rx) = tokio::sync::oneshot::channel();
    // Let the detached worker retain the admitted slot after downstream disconnect until terminal engine evidence arrives.
    tokio::spawn(async move {
        let result = tokio::time::timeout(
            Duration::from_secs(120),
            run_terminal(upstream, upstream_body, streaming, tx, head_tx),
        )
        .await;
        let (confirmed, success) = match result {
            Ok(Ok(v)) => v,
            _ => (false, false),
        };
        let _ = state.pools.finish(&state, id, confirmed, success);
        drop(ticket);
        if !confirmed {
            // An I/O body error leaves outcome_unknown and must not be mistaken for complete JSON or SSE.
            let _ = tokio::time::timeout(
                Duration::from_secs(1),
                failure_tx.send(Err(std::io::Error::other("POOL_UPSTREAM_INCOMPLETE"))),
            )
            .await;
        }
    });
    // Preserve engine status for streaming; delay nonstreaming 200 until bounded JSON contains terminal choices.
    let (status, response_streaming) = head_rx.await.map_err(|_| (
        StatusCode::BAD_GATEWAY,
        Json(json!({"error":{"code":"POOL_UPSTREAM_INCOMPLETE","message":"The engine outcome is unconfirmed; inspect the reservation before retrying","reservation_id":id}})),
    ))?;
    let mut response =
        Body::from_stream(tokio_stream::wrappers::ReceiverStream::new(rx)).into_response();
    *response.status_mut() = status;
    response.headers_mut().insert(
        "content-type",
        if response_streaming {
            "text/event-stream"
        } else {
            "application/json"
        }
        .parse()
        .expect("static content type"),
    );
    response.headers_mut().insert(
        "x-spark-reservation-id",
        reservation
            .reservation_id
            .to_string()
            .parse()
            .expect("UUID header"),
    );
    response.headers_mut().insert(
        "x-spark-attempt-id",
        reservation
            .attempt_id
            .to_string()
            .parse()
            .expect("UUID header"),
    );
    Ok(response)
}

/// Queue at most four 64 KiB chunks with backpressure; a hard deadline quarantines attempts lacking terminal evidence.
async fn run_terminal(
    upstream: crate::engine::EngineUpstream,
    body: Vec<u8>,
    streaming: bool,
    tx: tokio::sync::mpsc::Sender<Result<Bytes, std::io::Error>>,
    head: tokio::sync::oneshot::Sender<(StatusCode, bool)>,
) -> Result<(bool, bool), ()> {
    let client = reqwest::Client::builder()
        .no_proxy()
        .redirect(reqwest::redirect::Policy::none())
        .connect_timeout(Duration::from_secs(5))
        .build()
        .map_err(|_| ())?;
    let mut request = client
        .post(format!(
            "http://127.0.0.1:{}/v1/chat/completions",
            upstream.host_port
        ))
        .header("content-type", "application/json")
        .body(body);
    if !upstream.api_key.is_empty() {
        request = request.bearer_auth(upstream.api_key);
    }
    let response = request.send().await.map_err(|_| ())?;
    let status = response.status();
    let streaming = streaming && status.is_success();
    let mut head = Some(head);
    if streaming {
        let _ = head.take().expect("head").send((status, true));
    }
    let mut stream = response.bytes_stream();
    let mut pending = Vec::new();
    let mut framing = TerminalEvents::default();
    let mut disconnected = false;
    while let Some(chunk) = stream.next().await {
        let chunk = chunk.map_err(|_| ())?;
        if streaming {
            framing.push(&chunk)?;
            if !disconnected {
                for part in chunk.chunks(64 * 1024) {
                    if tx.send(Ok(Bytes::copy_from_slice(part))).await.is_err() {
                        disconnected = true;
                        break;
                    }
                }
            }
            if framing.completed {
                return Ok((true, !framing.reported_error));
            }
        } else {
            if pending.len().saturating_add(chunk.len()) > 2 * 1024 * 1024 {
                return Err(());
            }
            pending.extend_from_slice(&chunk);
        }
    }
    if streaming {
        return Err(());
    }
    let completed = serde_json::from_slice::<Value>(&pending)
        .ok()
        .is_some_and(|v| {
            v["choices"].as_array().is_some_and(|c| {
                !c.is_empty() && c.iter().all(|c| c["finish_reason"].as_str().is_some())
            })
        });
    if status.is_success() && !completed {
        return Err(());
    }
    let _ = head.take().expect("head").send((status, false));
    let _ = tx.send(Ok(Bytes::from(pending))).await;
    Ok((true, status.is_success()))
}

#[derive(Default)]
struct TerminalEvents {
    line: Vec<u8>,
    event_bytes: usize,
    data_lines: usize,
    terminal_data: bool,
    completed: bool,
    reported_error: bool,
}
impl TerminalEvents {
    fn push(&mut self, bytes: &[u8]) -> Result<(), ()> {
        for byte in bytes {
            self.event_bytes += 1;
            if self.event_bytes > 2 * 1024 * 1024 {
                return Err(());
            }
            if *byte != b'\n' {
                self.line.push(*byte);
                continue;
            }
            if self.line.last() == Some(&b'\r') {
                self.line.pop();
            }
            if self.line.is_empty() {
                self.completed |= self.data_lines == 1 && self.terminal_data;
                self.data_lines = 0;
                self.terminal_data = false;
                self.event_bytes = 0;
            } else if let Some(data) = self.line.strip_prefix(b"data:") {
                self.data_lines += 1;
                self.terminal_data = data.trim_ascii() == b"[DONE]";
                self.reported_error |= serde_json::from_slice::<Value>(data).is_ok_and(|v| {
                    v.get("error").is_some_and(|e| !e.is_null()) || v["object"] == "error"
                });
            }
            self.line.clear();
        }
        Ok(())
    }
}

#[cfg(test)]
#[path = "pool_api/tests.rs"]
mod tests;
