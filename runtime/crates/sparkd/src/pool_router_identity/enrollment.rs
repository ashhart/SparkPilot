use super::*;

pub fn verify_authority_anchor(public: &str, fingerprint: &str) -> Result<(), PoolError> {
    let bytes =
        hex::decode(public).map_err(|_| PoolError::Refused("POOL_ROUTER_IDENTITY_INVALID"))?;
    if bytes.len() != 32 || sha256_hex(&bytes) != fingerprint {
        return reject("POOL_ROUTER_IDENTITY_INVALID");
    }
    Ok(())
}

pub(super) fn verify_authority(
    public: &str,
    fingerprint: &str,
    bytes: &[u8],
    signature: &str,
) -> Result<(), PoolError> {
    let public =
        hex::decode(public).map_err(|_| PoolError::Refused("POOL_ROUTER_IDENTITY_INVALID"))?;
    if sha256_hex(&public) != fingerprint {
        return reject("POOL_ROUTER_IDENTITY_INVALID");
    }
    let public: [u8; 32] = public
        .try_into()
        .map_err(|_| PoolError::Refused("POOL_ROUTER_IDENTITY_INVALID"))?;
    let key = ed25519_dalek::VerifyingKey::from_bytes(&public)
        .map_err(|_| PoolError::Refused("POOL_ROUTER_IDENTITY_INVALID"))?;
    let signature = base64url_decode(signature)
        .map_err(|_| PoolError::Refused("POOL_ROUTER_IDENTITY_INVALID"))?;
    let signature = ed25519_dalek::Signature::from_slice(&signature)
        .map_err(|_| PoolError::Refused("POOL_ROUTER_IDENTITY_INVALID"))?;
    key.verify_strict(bytes, &signature)
        .map_err(|_| PoolError::Refused("POOL_ROUTER_IDENTITY_INVALID"))
}

pub fn verify_identity(
    doc: &RouterIdentityDocument,
    node: Uuid,
    anchor: &str,
) -> Result<Vec<u8>, PoolError> {
    if doc.protocol_version != 1
        || doc.key_generation == 0
        || doc.router_node_id != node
        || doc.authority_fingerprint != anchor
        || !pool::valid_digest(anchor)
    {
        return reject("POOL_ROUTER_IDENTITY_INVALID");
    }
    let der = base64url_decode(&doc.request_public_key_spki)
        .map_err(|_| PoolError::Refused("POOL_ROUTER_IDENTITY_INVALID"))?;
    if der.len() > 256
        || sha256_hex(&der) != doc.request_key_fingerprint
        || VerifyingKey::from_public_key_der(&der).is_err()
    {
        return reject("POOL_ROUTER_IDENTITY_INVALID");
    }
    verify_authority(
        &doc.authority_public_key,
        anchor,
        &identity_message(doc)?,
        &doc.authority_signature,
    )?;
    Ok(der)
}

pub fn create_challenge(
    conn: &Connection,
    state: &AppState,
    actor: Uuid,
    request: CreateRouterEnrollmentRequest,
) -> Result<Value, PoolError> {
    verify_identity(
        &request.identity,
        request.expected_router_node_id,
        &request.expected_router_authority_fingerprint,
    )?;
    if request.display_name.trim().is_empty()
        || request.display_name.len() > 80
        || request.display_name.chars().any(char::is_control)
    {
        return reject("POOL_REQUEST_INVALID");
    }
    let now = state.clock.now().unix_timestamp();
    conn.execute(
        "DELETE FROM pool_router_enrollments WHERE expires_at<=?1",
        [now],
    )?;
    let count: u32 = conn.query_row("SELECT count(*) FROM pool_router_enrollments", [], |r| {
        r.get(0)
    })?;
    if count >= 128 {
        return reject("POOL_ROUTER_ENROLLMENT_LIMIT");
    }
    let tls = state
        .tls_fingerprint
        .as_deref()
        .filter(|s| pool::valid_digest(s))
        .ok_or(PoolError::Refused("POOL_ROUTER_TLS_REQUIRED"))?;
    let mut challenge = RouterEnrollmentChallenge {
        challenge_id: Uuid::new_v4(),
        nonce: base64url_encode(Uuid::new_v4().as_bytes()),
        issued_at: now,
        expires_at: now + 60,
        recipient_node_id: state.identity.node_id(),
        recipient_authority_public_key: state.identity.public.authority_public_key.clone(),
        recipient_authority_fingerprint: state.identity.public.authority_fingerprint.clone(),
        recipient_tls_certificate_sha256: tls.into(),
        router_identity: request.identity,
        recipient_authority_signature: String::new(),
    };
    challenge.recipient_authority_signature = base64url_encode(
        &state
            .identity
            .signing_key()
            .sign(&challenge_message(&challenge)?)
            .to_bytes(),
    );
    conn.execute(
        "INSERT INTO pool_router_enrollments VALUES(?1,?2,?3,?4,?5,0)",
        params![
            challenge.challenge_id.to_string(),
            actor.to_string(),
            request.display_name,
            serde_json::to_string(&challenge)?,
            challenge.expires_at
        ],
    )?;
    Ok(serde_json::to_value(challenge)?)
}

pub fn validate_proof_request(
    state: &AppState,
    request: &ProveRouterEnrollmentRequest,
) -> Result<RouterKey, PoolError> {
    let c = &request.challenge;
    let trust = &request.recipient;
    let now = state.clock.now().unix_timestamp();
    if c.recipient_node_id != trust.node_id
        || c.recipient_authority_fingerprint != trust.authority_fingerprint
        || c.recipient_tls_certificate_sha256 != trust.tls_certificate_sha256
        || c.expires_at <= now
        || c.issued_at > now
        || c.expires_at - c.issued_at != 60
    {
        return reject("POOL_ROUTER_CHALLENGE_INVALID");
    }
    verify_authority(
        &c.recipient_authority_public_key,
        &trust.authority_fingerprint,
        &challenge_message(c)?,
        &c.recipient_authority_signature,
    )?;
    let key = state.router_identity.load()?;
    if key.document(state)? != c.router_identity {
        return reject("POOL_ROUTER_KEY_CHANGED");
    }
    Ok(key)
}

pub fn prove(
    conn: &Connection,
    state: &AppState,
    actor: Uuid,
    request: ProveRouterEnrollmentRequest,
) -> Result<Value, PoolError> {
    let key = validate_proof_request(state, &request)?;
    let c = &request.challenge;
    let trust = &request.recipient;
    let now = state.clock.now().unix_timestamp();
    let signature: Signature = key.signing.sign(&message("SPARK-POOL-POSSESSION-1\n", c)?);
    let proof = RouterEnrollmentProof {
        challenge_id: c.challenge_id,
        recipient_node_id: c.recipient_node_id,
        principal_id: key.principal_id,
        challenge_sha256: pool::digest(c)?,
        possession_signature: base64url_encode(&signature.to_bytes()),
    };
    let count: u32 = conn.query_row(
        "SELECT count(DISTINCT node_id) FROM pool_router_peers",
        [],
        |r| r.get(0),
    )?;
    let exists: bool = conn.query_row(
        "SELECT EXISTS(SELECT 1 FROM pool_router_peers WHERE node_id=?1)",
        [trust.node_id.to_string()],
        |r| r.get(0),
    )?;
    if count >= 16 && !exists {
        return reject("POOL_ROUTER_PEER_LIMIT");
    }
    let records: u32 =
        conn.query_row("SELECT count(*) FROM pool_router_peers", [], |r| r.get(0))?;
    let recorded: bool = conn.query_row(
        "SELECT EXISTS(SELECT 1 FROM pool_router_peers WHERE node_id=?1 AND principal_id=?2)",
        params![trust.node_id.to_string(), key.principal_id.to_string()],
        |r| r.get(0),
    )?;
    if records >= 256 && !recorded {
        return reject("POOL_ROUTER_PEER_LIMIT");
    }
    conn.execute("INSERT INTO pool_router_peers VALUES(?1,?2,?3,?4,?5,?6) ON CONFLICT(node_id,principal_id) DO UPDATE SET trust_json=excluded.trust_json,authority_public_key=excluded.authority_public_key,approved_by_device_id=excluded.approved_by_device_id,approved_at=excluded.approved_at",params![trust.node_id.to_string(),key.principal_id.to_string(),serde_json::to_string(trust)?,c.recipient_authority_public_key,actor.to_string(),now])?;
    Ok(serde_json::to_value(proof)?)
}

pub fn enroll(
    conn: &Connection,
    state: &AppState,
    actor: Uuid,
    id: Uuid,
    proof: RouterEnrollmentProof,
) -> Result<Value, PoolError> {
    let row:Option<(String,String,bool)>=conn.query_row("SELECT challenge_json,display_name,consumed FROM pool_router_enrollments WHERE challenge_id=?1 AND actor_device_id=?2",params![id.to_string(),actor.to_string()],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?))).optional()?;
    let Some((raw, name, consumed)) = row else {
        return reject("POOL_ROUTER_CHALLENGE_INVALID");
    };
    let c: RouterEnrollmentChallenge = serde_json::from_str(&raw)?;
    if consumed
        || c.expires_at <= state.clock.now().unix_timestamp()
        || c.recipient_node_id != state.identity.node_id()
        || proof.challenge_id != id
        || proof.principal_id != c.router_identity.principal_id
        || proof.recipient_node_id != c.recipient_node_id
        || proof.challenge_sha256 != pool::digest(&c)?
        || state.tls_fingerprint.as_deref() != Some(c.recipient_tls_certificate_sha256.as_str())
    {
        return reject("POOL_ROUTER_CHALLENGE_INVALID");
    }
    let der = verify_identity(
        &c.router_identity,
        c.router_identity.router_node_id,
        &c.router_identity.authority_fingerprint,
    )?;
    let key = VerifyingKey::from_public_key_der(&der)
        .map_err(|_| PoolError::Refused("POOL_ROUTER_IDENTITY_INVALID"))?;
    let signature = base64url_decode(&proof.possession_signature)
        .map_err(|_| PoolError::Refused("POOL_ROUTER_POSSESSION_INVALID"))?;
    let signature = Signature::from_slice(&signature)
        .map_err(|_| PoolError::Refused("POOL_ROUTER_POSSESSION_INVALID"))?;
    key.verify(&message("SPARK-POOL-POSSESSION-1\n", &c)?, &signature)
        .map_err(|_| PoolError::Refused("POOL_ROUTER_POSSESSION_INVALID"))?;
    if crate::store::load_device_by_id(conn, &proof.principal_id)
        .map_err(|_| PoolError::Refused("POOL_STORAGE_UNAVAILABLE"))?
        .is_some()
    {
        return reject("POOL_ROUTER_IDENTITY_INVALID");
    }
    let existing: Option<(String,String)> = conn.query_row("SELECT router_node_id,request_key_fingerprint FROM pool_router_principals WHERE principal_id=?1", [proof.principal_id.to_string()], |r|Ok((r.get(0)?,r.get(1)?))).optional()?;
    if existing.as_ref().is_some_and(|(node, key)| {
        node != &c.router_identity.router_node_id.to_string()
            || key != &c.router_identity.request_key_fingerprint
    }) {
        return reject("POOL_ROUTER_IDENTITY_INVALID");
    }
    let count: u32 = conn.query_row("SELECT count(*) FROM pool_router_principals", [], |r| {
        r.get(0)
    })?;
    if existing.is_none() && count >= 256 {
        return reject("POOL_ROUTER_PRINCIPAL_LIMIT");
    }
    let old: Vec<String> = conn
        .prepare(
            "SELECT principal_id FROM pool_router_principals WHERE router_node_id=?1 AND revoked=0",
        )?
        .query_map([c.router_identity.router_node_id.to_string()], |r| r.get(0))?
        .collect::<Result<_, _>>()?;
    for old in old {
        revoke(
            conn,
            Uuid::parse_str(&old).map_err(|_| PoolError::Refused("POOL_STORAGE_UNAVAILABLE"))?,
        )?;
    }
    let now = state.clock.now().unix_timestamp();
    conn.execute("INSERT INTO pool_router_principals VALUES(?1,'pool_router',?2,?3,?4,?5,?6,?7,?8,0) ON CONFLICT(principal_id) DO UPDATE SET revoked=0,enrolled_by_device_id=excluded.enrolled_by_device_id,display_name=excluded.display_name,enrolled_at=excluded.enrolled_at",params![proof.principal_id.to_string(),c.router_identity.router_node_id.to_string(),der,c.router_identity.request_key_fingerprint,c.router_identity.authority_fingerprint,actor.to_string(),name,now])?;
    conn.execute(
        "UPDATE pool_router_enrollments SET consumed=1 WHERE challenge_id=?1",
        [id.to_string()],
    )?;
    Ok(serde_json::to_value(EnrolledRouterPrincipal {
        principal_id: proof.principal_id,
        kind: ROLE.into(),
        router_node_id: c.router_identity.router_node_id,
        request_key_fingerprint: c.router_identity.request_key_fingerprint,
        recipient_node_id: state.identity.node_id(),
        display_name: name,
        enrolled_at: now,
        revoked: false,
    })?)
}

pub fn revoke(conn: &Connection, id: Uuid) -> Result<Value, PoolError> {
    if conn.execute(
        "UPDATE pool_router_principals SET revoked=1 WHERE principal_id=?1",
        [id.to_string()],
    )? == 0
    {
        return reject("POOL_NOT_FOUND");
    }
    conn.execute("UPDATE inference_router_grants SET revoked=1 WHERE grant_id IN (SELECT grant_id FROM inference_router_grants WHERE json_extract(grant_json,'$.scope.router_device_id')=?1)",[id.to_string()])?;
    conn.execute("UPDATE inference_reservations SET state='cancelled',reason='not_dispatched' WHERE router_device_id=?1 AND state='reserved'",[id.to_string()])?;
    Ok(json!({"principal_id":id,"revoked":true,"accepted_work":"drain"}))
}
