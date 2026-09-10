use super::*;

/// The signed invitation payload (matches the pairing-invite JSON Schema).
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub struct InvitationPayload {
    pub version: u32,
    pub node_id: uuid::Uuid,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cluster_id: Option<uuid::Uuid>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub local_endpoint: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub remote_endpoint: Option<String>,
    pub authority_fingerprint: String,
    pub invitation_id: uuid::Uuid,
    pub nonce: String,
    /// Use the authenticated issuing Apple device; an outer multi-Spark manifest cannot select the issuer.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub issued_by_device_id: Option<uuid::Uuid>,
    /// Batch handoffs require both recipient bindings; legacy single-node invitations omit both.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub recipient_device_id: Option<uuid::Uuid>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub recipient_public_key_fingerprint: Option<String>,
    pub role: String,
    pub expires_at: String,
    /// Version 2 fields sit here, before the signature member, so a version 1 payload signs exactly the bytes it always did.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub node_name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tls_fingerprint: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub remote_hostname: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub shared_access: Option<SharedAccessSummary>,
    /// Always present and null in the canonical bytes; the signature is the last member.
    #[serde(default)]
    pub signature: Option<String>,
}

/// The version this runtime issues when an invitation carries connection details or a shared-access policy.
pub const INVITATION_VERSION_WITH_ROUTES: u32 = 2;

/// Cap a guest invitation's life; it is a bearer capability, but it grants only a pending guest the owner must still confirm.
pub const GUEST_INVITATION_MAX_SECONDS: i64 = 7 * 24 * 60 * 60;

/// The role name a shared-access invitation carries; it is not one of the ordinary pairing roles.
pub const GUEST_ROLE: &str = "guest";

/// The limits the friend can read before joining, signed with the rest of the invitation.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub struct SharedAccessSummary {
    pub display_name: String,
    pub allowed_models: Vec<String>,
    pub allowed_hours: Vec<crate::guest::DaySchedule>,
    pub time_zone: String,
    pub max_concurrent_requests: u32,
    pub daily_token_budget: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub expires_at: Option<i64>,
}

impl InvitationPayload {
    /// Canonicalize declaration-ordered compact JSON with signature set to null, preserving the shared invitation signing bytes.
    pub fn canonical_without_signature(&self) -> Result<Vec<u8>, serde_json::Error> {
        let mut clone = self.clone();
        clone.signature = None;
        serde_json::to_vec(&clone)
    }

    pub fn sign(&mut self, identity: &NodeIdentity) -> Result<(), PairingError> {
        let canonical = self.canonical_without_signature()?;
        let signature = identity.signing_key().sign(&canonical);
        self.signature = Some(base64url_encode(&signature.to_bytes()));
        Ok(())
    }

    pub fn verify(&self, identity: &NodeIdentity) -> Result<(), PairingError> {
        let signature_text = self
            .signature
            .as_ref()
            .ok_or_else(|| PairingError::InvalidInvitation("missing signature".into()))?;
        let signature_bytes = base64url_decode(signature_text)?;
        let signature_bytes: [u8; 64] = signature_bytes
            .try_into()
            .map_err(|_| PairingError::InvalidInvitation("signature length".into()))?;
        let signature = Signature::from_bytes(&signature_bytes);
        let canonical = self.canonical_without_signature()?;
        identity
            .public
            .verifying_key()
            .map_err(|e| PairingError::InvalidInvitation(e.to_string()))?
            .verify(&canonical, &signature)
            .map_err(|_| PairingError::InvalidInvitation("signature does not verify".into()))
    }
}

/// A signed pairing invitation issued by the owner/administrator.
pub struct IssuedInvitation {
    pub payload: InvitationPayload,
    pub expires_at: String,
    pub join_code: String,
}

pub(super) fn join_code_hash(code: &str) -> Vec<u8> {
    sha256_fingerprint_bytes(format!("spark-pairing-join-code-v1:{code}").as_bytes())
}

pub(super) fn new_join_code(conn: &Connection) -> Result<(String, Vec<u8>), PairingError> {
    for _ in 0..32 {
        let value = rand::rng().random_range(0..1_000_000_u32);
        let code = format!("{value:06}");
        let hash = join_code_hash(&code);
        if !store::active_join_code_exists(conn, &hash)? {
            return Ok((code, hash));
        }
    }
    Err(PairingError::InvalidInvitation(
        "a unique join code could not be allocated".into(),
    ))
}

pub fn issue_invitation(
    conn: &Connection,
    identity: &NodeIdentity,
    issued_by: &uuid::Uuid,
    role: String,
    expires_in_seconds: Option<i64>,
    device_name_hint: Option<String>,
) -> Result<IssuedInvitation, PairingError> {
    issue_invitation_for_recipient(
        conn,
        identity,
        issued_by,
        role,
        expires_in_seconds,
        device_name_hint,
        None,
    )
}

pub fn issue_invitation_for_recipient(
    conn: &Connection,
    identity: &NodeIdentity,
    issued_by: &uuid::Uuid,
    role: String,
    expires_in_seconds: Option<i64>,
    device_name_hint: Option<String>,
    recipient: Option<(uuid::Uuid, String)>,
) -> Result<IssuedInvitation, PairingError> {
    if !ROLES.contains(&role.as_str()) {
        return Err(PairingError::RoleMismatch("unknown role"));
    }
    if let Some((_, fingerprint)) = &recipient
        && (fingerprint.len() != 64
            || !fingerprint
                .bytes()
                .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase()))
    {
        return Err(PairingError::InvalidInvitation(
            "recipient public-key fingerprint must be 64 lowercase hex characters".into(),
        ));
    }
    let seconds = expires_in_seconds
        .unwrap_or(INVITATION_DEFAULT_SECONDS)
        .clamp(INVITATION_MIN_SECONDS, INVITATION_MAX_SECONDS);

    if role == "owner" && store::has_owner(conn)? {
        return Err(PairingError::OwnerAlreadyExists);
    }

    let invitation_id = uuid::Uuid::new_v4();
    let now = OffsetDateTime::now_utc();
    let expires_at = now + time::Duration::seconds(seconds);

    let mut nonce = [0u8; 32];
    rand::rng().fill_bytes(&mut nonce);

    let mut payload = InvitationPayload {
        version: 1,
        node_id: identity.node_id(),
        cluster_id: None,
        local_endpoint: None,
        remote_endpoint: None,
        authority_fingerprint: identity.fingerprint().to_owned(),
        invitation_id,
        nonce: base64url_encode(&nonce),
        issued_by_device_id: Some(*issued_by),
        recipient_device_id: recipient.as_ref().map(|(device_id, _)| *device_id),
        recipient_public_key_fingerprint: recipient.map(|(_, fingerprint)| fingerprint),
        role: role.clone(),
        expires_at: rfc3339(expires_at),
        node_name: None,
        tls_fingerprint: None,
        remote_hostname: None,
        shared_access: None,
        signature: None,
    };
    payload.sign(identity)?;

    let signed_json = serde_json::to_string(&payload)?;
    let (join_code, join_code_hash) = new_join_code(conn)?;
    store::insert_invitation(
        conn,
        &store::InvitationDraft {
            id: &invitation_id,
            role: &role,
            nonce_hash: &sha256_fingerprint_bytes(&nonce),
            issued_by,
            device_name_hint: device_name_hint.as_deref(),
            expires_at: &rfc3339(expires_at),
            signed_payload_json: &signed_json,
            join_code_hash: &join_code_hash,
        },
    )?;

    Ok(IssuedInvitation {
        payload,
        expires_at: rfc3339(expires_at),
        join_code,
    })
}

/// The connection details a friend needs, carried inside the signature so they cannot be swapped.
#[derive(Debug, Clone, Default)]
pub struct InvitationRoutes {
    pub node_name: String,
    pub tls_fingerprint: Option<String>,
    pub local_endpoint: Option<String>,
    pub remote_endpoint: Option<String>,
    pub remote_hostname: Option<String>,
}

/// Issue the shared-access invitation: a version 2 payload naming the routes, the pin and the limits.
pub fn issue_guest_invitation(
    conn: &Connection,
    identity: &NodeIdentity,
    issued_by: &uuid::Uuid,
    summary: SharedAccessSummary,
    routes: &InvitationRoutes,
    expires_in_seconds: Option<i64>,
) -> Result<IssuedInvitation, PairingError> {
    let seconds = expires_in_seconds
        .unwrap_or(GUEST_INVITATION_MAX_SECONDS)
        .clamp(INVITATION_MIN_SECONDS, GUEST_INVITATION_MAX_SECONDS);
    let invitation_id = uuid::Uuid::new_v4();
    let expires_at = OffsetDateTime::now_utc() + time::Duration::seconds(seconds);
    let mut nonce = [0u8; 32];
    rand::rng().fill_bytes(&mut nonce);
    let mut payload = InvitationPayload {
        version: INVITATION_VERSION_WITH_ROUTES,
        node_id: identity.node_id(),
        cluster_id: None,
        local_endpoint: routes.local_endpoint.clone(),
        remote_endpoint: routes.remote_endpoint.clone(),
        authority_fingerprint: identity.fingerprint().to_owned(),
        invitation_id,
        nonce: base64url_encode(&nonce),
        issued_by_device_id: Some(*issued_by),
        recipient_device_id: None,
        recipient_public_key_fingerprint: None,
        role: GUEST_ROLE.to_owned(),
        expires_at: rfc3339(expires_at),
        node_name: Some(routes.node_name.clone()),
        tls_fingerprint: routes.tls_fingerprint.clone(),
        remote_hostname: routes.remote_hostname.clone(),
        shared_access: Some(summary),
        signature: None,
    };
    payload.sign(identity)?;
    let signed_json = serde_json::to_string(&payload)?;
    let (join_code, join_code_hash) = new_join_code(conn)?;
    store::insert_invitation(
        conn,
        &store::InvitationDraft {
            id: &invitation_id,
            role: GUEST_ROLE,
            nonce_hash: &sha256_fingerprint_bytes(&nonce),
            issued_by,
            device_name_hint: None,
            expires_at: &rfc3339(expires_at),
            signed_payload_json: &signed_json,
            join_code_hash: &join_code_hash,
        },
    )?;
    Ok(IssuedInvitation {
        payload,
        expires_at: rfc3339(expires_at),
        join_code,
    })
}

/// Limit each node to 60 wrong six-digit codes so additional source addresses cannot expand the guessing budget.
pub const MAX_FAILED_JOIN_CODES: i64 = 60;

/// Count failures across the full maximum invitation lifetime so a still-live code cannot outlast the budget.
pub const JOIN_CODE_FAILURE_WINDOW_MINUTES: i64 = 15;

pub fn redeem_join_code(conn: &Connection, code: &str) -> Result<InvitationPayload, PairingError> {
    if code.len() != 6 || !code.bytes().all(|byte| byte.is_ascii_digit()) {
        return Err(PairingError::InvalidJoinCode);
    }
    let window_start = crate::store::now_iso8601_minus_minutes(JOIN_CODE_FAILURE_WINDOW_MINUTES);
    let recent_failures: i64 = conn.query_row(
        "SELECT COUNT(*) FROM join_code_attempts WHERE attempted_at >= ?1",
        rusqlite::params![window_start],
        |row| row.get(0),
    )?;
    if recent_failures >= MAX_FAILED_JOIN_CODES {
        return Err(PairingError::TooManyJoinCodeAttempts {
            retry_after_seconds: join_code_retry_after_seconds(conn, &window_start)?,
        });
    }

    let found = store::load_pending_invitation_by_join_code(conn, &join_code_hash(code))?;
    let Some(row) = found else {
        // Record misses and prune expired attempts together to bound the table.
        conn.execute(
            "INSERT INTO join_code_attempts (attempted_at) VALUES (?1)",
            rusqlite::params![crate::store::now_iso8601()],
        )?;
        conn.execute(
            "DELETE FROM join_code_attempts WHERE attempted_at < ?1",
            rusqlite::params![window_start],
        )?;
        return Err(PairingError::InvalidJoinCode);
    };
    let payload: InvitationPayload = serde_json::from_str(&row.signed_payload_json)?;
    Ok(payload)
}

/// Seconds until the oldest counted failure leaves the window, so a locked node can say when to try again.
pub fn join_code_retry_after_seconds(
    conn: &Connection,
    window_start: &str,
) -> Result<u64, PairingError> {
    let oldest: Option<String> = conn.query_row(
        "SELECT MIN(attempted_at) FROM join_code_attempts WHERE attempted_at >= ?1",
        rusqlite::params![window_start],
        |row| row.get(0),
    )?;
    let Some(oldest) = oldest else {
        return Ok(60);
    };
    let oldest =
        time::OffsetDateTime::parse(&oldest, &time::format_description::well_known::Rfc3339)?;
    let remaining = oldest + time::Duration::minutes(JOIN_CODE_FAILURE_WINDOW_MINUTES)
        - time::OffsetDateTime::now_utc();
    Ok(remaining
        .whole_seconds()
        .clamp(1, JOIN_CODE_FAILURE_WINDOW_MINUTES * 60) as u64)
}

/// Failures counted in the current window; the handler reports the moment the budget is spent.
pub fn join_code_failures_in_window(conn: &Connection) -> Result<i64, PairingError> {
    let window_start = crate::store::now_iso8601_minus_minutes(JOIN_CODE_FAILURE_WINDOW_MINUTES);
    Ok(conn.query_row(
        "SELECT COUNT(*) FROM join_code_attempts WHERE attempted_at >= ?1",
        rusqlite::params![window_start],
        |row| row.get(0),
    )?)
}
