use super::*;

pub const CHARGED: &str = "('reserved','accepted','cancel_requested','outcome_unknown')";

#[derive(Debug, thiserror::Error)]
pub enum PoolError {
    #[error("{0}")]
    Refused(&'static str),
    #[error("pool storage unavailable")]
    Storage(#[from] rusqlite::Error),
    #[error("pool document invalid")]
    Document(#[from] serde_json::Error),
    #[error("engine unavailable: {0:?}")]
    Engine(EngineError),
}

impl From<EngineError> for PoolError {
    fn from(value: EngineError) -> Self {
        Self::Engine(value)
    }
}

impl PoolError {
    pub fn envelope(self) -> (StatusCode, Json<Value>) {
        if let Self::Engine(error) = self {
            return error.envelope();
        }
        let code = match self {
            Self::Refused(code) => code,
            _ => "POOL_STORAGE_UNAVAILABLE",
        };
        let status = match code {
            "POOL_ROLE_FORBIDDEN" | "POOL_GRANT_FORBIDDEN" | "POOL_LOCAL_ROUTE_REQUIRED" => {
                StatusCode::FORBIDDEN
            }
            "POOL_NOT_FOUND" => StatusCode::NOT_FOUND,
            "POOL_REQUEST_INVALID" => StatusCode::BAD_REQUEST,
            "POOL_STORAGE_UNAVAILABLE" => StatusCode::SERVICE_UNAVAILABLE,
            _ => StatusCode::CONFLICT,
        };
        (
            status,
            Json(
                json!({"error":{"code":code,"message":code,"request_id":crate::route::current_request_id()}}),
            ),
        )
    }
}

pub(crate) fn refuse<T>(code: &'static str) -> Result<T, PoolError> {
    Err(PoolError::Refused(code))
}

pub fn database(state: &AppState) -> Result<&Arc<Mutex<Connection>>, PoolError> {
    state
        .database
        .as_ref()
        .ok_or(PoolError::Refused("POOL_STORAGE_UNAVAILABLE"))
}

pub fn digest(value: &impl serde::Serialize) -> Result<String, PoolError> {
    Ok(sha256_hex(&serde_json::to_vec(value)?))
}

pub fn valid_digest(s: &str) -> bool {
    s.len() == 64
        && s.bytes()
            .all(|c| c.is_ascii_digit() || (b'a'..=b'f').contains(&c))
}

pub fn lookup_mutation(
    conn: &Connection,
    key: &IdempotencyRequest,
) -> Result<Option<Value>, PoolError> {
    let row:Option<(String,String)>=conn.query_row("SELECT body_sha256,response_json FROM inference_pool_mutations WHERE actor_device_id=?1 AND path=?2 AND idempotency_key=?3",params![key.device_id.to_string(),key.path,key.key.to_string()],|r|Ok((r.get(0)?,r.get(1)?))).optional()?;
    match row {
        Some((hash, raw)) => {
            if hash != key.body_hash {
                return refuse("IDEMPOTENCY_KEY_REUSED");
            }
            Ok(Some(serde_json::from_str(&raw)?))
        }
        None => Ok(None),
    }
}

pub fn store_mutation(
    conn: &Connection,
    key: &IdempotencyRequest,
    value: &Value,
    now: i64,
) -> Result<(), PoolError> {
    let count: u32 = conn.query_row("SELECT count(*) FROM inference_pool_mutations", [], |r| {
        r.get(0)
    })?;
    if count >= 32768 {
        return refuse("POOL_RECEIPT_LIMIT");
    }
    conn.execute(
        "INSERT INTO inference_pool_mutations VALUES(?1,?2,?3,?4,?5,?6)",
        params![
            key.device_id.to_string(),
            key.path,
            key.key.to_string(),
            key.body_hash,
            serde_json::to_string(value)?,
            now
        ],
    )?;
    Ok(())
}

pub fn eligible_device(conn: &Connection, id: Uuid) -> Result<(), PoolError> {
    let device = crate::store::load_device_by_id(conn, &id)
        .map_err(|_| PoolError::Refused("POOL_STORAGE_UNAVAILABLE"))?;
    if !device.is_some_and(|d| {
        matches!(
            d.role.as_str(),
            "owner" | "administrator" | "developer" | "user"
        )
    }) {
        return refuse("POOL_GRANT_FORBIDDEN");
    }
    Ok(())
}

pub fn eligible_router(conn: &Connection, id: Uuid) -> Result<(), PoolError> {
    if crate::pool_router_identity::load_principal(conn, id)?.is_some() {
        return Ok(());
    }
    eligible_device(conn, id)
}

pub fn eligible_owner(conn: &Connection, id: Uuid) -> Result<(), PoolError> {
    let current = crate::store::load_device_by_id(conn, &id)
        .map_err(|_| PoolError::Refused("POOL_STORAGE_UNAVAILABLE"))?;
    if current.is_none_or(|d| d.role != "owner") {
        return refuse("POOL_ROLE_FORBIDDEN");
    }
    Ok(())
}

pub fn validate_request_age(id: Uuid, now_milliseconds: i64) -> Result<i64, PoolError> {
    if id.get_version_num() != 7 || id.get_variant() != uuid::Variant::RFC4122 {
        return refuse("POOL_REQUEST_ID_INVALID");
    }
    let bytes = id.as_bytes();
    let issued = bytes[..6]
        .iter()
        .fold(0_i64, |v, b| (v << 8) | i64::from(*b));
    if issued < now_milliseconds.saturating_sub(NEW_REQUEST_WINDOW_MILLISECONDS)
        || issued > now_milliseconds.saturating_add(REQUEST_FUTURE_SKEW_MILLISECONDS)
    {
        return refuse("POOL_REQUEST_ID_EXPIRED");
    }
    Ok(issued)
}

pub fn policy_revision(conn: &Connection, id: Uuid) -> Result<u64, PoolError> {
    Ok(conn
        .query_row(
            "SELECT revision FROM inference_pool_policies WHERE pool_id=?1",
            [id.to_string()],
            |r| r.get(0),
        )
        .optional()?
        .unwrap_or(0))
}

pub fn load_policy(conn: &Connection, id: Uuid) -> Result<InferencePoolPolicy, PoolError> {
    let raw: Option<String> = conn
        .query_row(
            "SELECT policy_json FROM inference_pool_policies WHERE pool_id=?1",
            [id.to_string()],
            |r| r.get(0),
        )
        .optional()?;
    Ok(serde_json::from_str(
        &raw.ok_or(PoolError::Refused("POOL_NOT_FOUND"))?,
    )?)
}

pub(super) fn reservation_grant(conn: &Connection, id: Uuid) -> Result<Uuid, PoolError> {
    let raw: Option<String> = conn
        .query_row(
            "SELECT grant_id FROM inference_reservations WHERE reservation_id=?1",
            [id.to_string()],
            |r| r.get(0),
        )
        .optional()?;
    Uuid::parse_str(&raw.ok_or(PoolError::Refused("POOL_NOT_FOUND"))?)
        .map_err(|_| PoolError::Refused("POOL_STORAGE_UNAVAILABLE"))
}

pub fn read_reservation(
    conn: &Connection,
    node_id: Uuid,
    id: Uuid,
) -> Result<AdmissionReservation, PoolError> {
    let value:Option<Value>=conn.query_row("SELECT request_id,attempt_id,pool_id,caller_device_id,deployment_id,policy_revision,context_budget,output_budget,state,expires_at,reason,engine_instance_id,capacity_released FROM inference_reservations WHERE reservation_id=?1",[id.to_string()],|r|Ok(json!({"reservation_id":id,"node_id":node_id,"request_id":r.get::<_,String>(0)?,"attempt_id":r.get::<_,String>(1)?,"pool_id":r.get::<_,String>(2)?,"caller_device_id":r.get::<_,String>(3)?,"deployment_id":r.get::<_,String>(4)?,"policy_revision":r.get::<_,u64>(5)?,"context_budget":r.get::<_,u64>(6)?,"output_budget":r.get::<_,u32>(7)?,"state":r.get::<_,String>(8)?,"expires_at":r.get::<_,i64>(9)?,"reason":r.get::<_,Option<String>>(10)?,"engine_instance_id":r.get::<_,String>(11)?,"capacity_released":r.get::<_,bool>(12)?}))).optional()?;
    Ok(serde_json::from_value(
        value.ok_or(PoolError::Refused("POOL_NOT_FOUND"))?,
    )?)
}

pub(super) fn validate_policy(p: &InferencePoolPolicy, node: Uuid) -> Result<(), PoolError> {
    if p.display_name.trim().is_empty()
        || p.display_name.len() > 80
        || p.display_name.chars().any(char::is_control)
        || p.revision == 0
        || p.revision > i64::MAX as u64
        || p.node_ids.is_empty()
        || p.node_ids.len() > 16
        || !p.node_ids.contains(&node)
        || p.caller_device_ids.is_empty()
        || p.caller_device_ids.len() > 64
        || p.router_device_ids.len() != 1
        || p.deployment_ids.is_empty()
        || p.deployment_ids.len() > 16
        || p.deployment_ids.iter().any(|d| !valid_digest(d))
        || !p.local_only
        || !(1..=128).contains(&p.max_concurrent_requests)
        || p.max_concurrent_per_caller == 0
        || p.max_concurrent_per_caller > p.max_concurrent_requests
        || p.max_queued_per_caller > 32
        || p.max_queued_requests > 128
        || p.max_buffered_bytes == 0
        || p.max_buffered_bytes > 64 * 1024 * 1024
    {
        return refuse("POOL_REQUEST_INVALID");
    }
    Ok(())
}
