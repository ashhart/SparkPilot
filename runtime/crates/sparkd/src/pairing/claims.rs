use super::*;

/// Request body for `POST /api/v1/pairing/claim`.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "snake_case")]
pub struct ClaimRequest {
    pub invitation: InvitationPayload,
    pub challenge_id: uuid::Uuid,
    pub device_id: uuid::Uuid,
    pub device_name: String,
    pub platform: String,               // ios | ipados | macos
    pub device_public_key_spki: String, // base64
    #[serde(default)]
    pub presence_public_key_spki: Option<String>, // base64, separate P-256 key
    #[serde(default)]
    pub presence_key_signature: Option<String>, // base64url ECDSA r||s
    pub challenge_signature: String,    // base64url ECDSA r||s
}

/// Response body for the claim endpoint.
#[derive(Debug, Serialize)]
#[serde(rename_all = "snake_case")]
pub struct ClaimResponse {
    pub device: DeviceGrant,
    pub authority_certificate: String, // base64 node authority public key
    pub issued_at: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub presence_key_fingerprint: Option<String>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "snake_case")]
pub struct DeviceGrant {
    pub id: uuid::Uuid,
    pub display_name: String,
    pub platform: String,
    pub role: String,
    pub paired_at: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_seen_at: Option<String>,
    pub revoked: bool,
}

/// A guest device is stored with the lowest existing role; only its grant raises it, so losing the grant can only reduce access.
pub(crate) fn stored_device_role(invitation_role: &str) -> &str {
    if invitation_role == super::GUEST_ROLE {
        "observer"
    } else {
        invitation_role
    }
}

/// Audit public claim refusals only for genuine live pairing state so malformed unauthenticated requests cannot amplify audit writes.
pub(crate) fn claim_refusal_is_auditable(
    conn: &Connection,
    identity: &NodeIdentity,
    now: OffsetDateTime,
    request: &ClaimRequest,
) -> Result<bool, StoreError> {
    if request.invitation.verify(identity).is_err()
        || request.invitation.node_id != identity.node_id()
    {
        return Ok(false);
    }
    let Some(invitation) = store::load_pending_invitation(conn, &request.invitation.invitation_id)?
    else {
        return Ok(false);
    };
    let Ok(submitted_payload) = serde_json::to_string(&request.invitation) else {
        return Ok(false);
    };
    let Ok(invitation_expiry) = parse_rfc3339(&invitation.expires_at) else {
        return Ok(false);
    };
    if invitation.signed_payload_json != submitted_payload || now > invitation_expiry {
        return Ok(false);
    }
    let Some(challenge) = store::load_challenge(conn, &request.challenge_id)? else {
        return Ok(false);
    };
    let Ok(challenge_expiry) = parse_rfc3339(&challenge.expires_at) else {
        return Ok(false);
    };
    Ok(challenge.invitation_id == request.invitation.invitation_id && now <= challenge_expiry)
}

pub fn claim_invitation(
    conn: &mut Connection,
    identity: &NodeIdentity,
    clock: &dyn crate::clock::UtcClock,
    request: &ClaimRequest,
) -> Result<ClaimResponse, PairingError> {
    // 1. Invitation structure + signature.
    let invitation = &request.invitation;
    invitation.verify(identity)?;
    if invitation.node_id != identity.node_id() {
        return Err(PairingError::InvalidInvitation("mismatched node id".into()));
    }
    let expires_at = parse_rfc3339(&invitation.expires_at)?;
    let recovering_existing_grant =
        store::consumed_invitation_grant(conn, &invitation.invitation_id)?.is_some();
    if !recovering_existing_grant && OffsetDateTime::now_utc() > expires_at {
        return Err(StoreError::InvitationExpired.into());
    }

    // 2. Challenge lookup, ownership, lifetime, and single-claim.
    let challenge = store::load_challenge(conn, &request.challenge_id)?
        .ok_or(StoreError::NotFound("challenge"))?;
    if challenge.invitation_id != request.invitation.invitation_id {
        return Err(PairingError::ChallengeMismatch(
            "challenge was issued for a different invitation".into(),
        ));
    }
    let challenge_expiry = parse_rfc3339(&challenge.expires_at)?;
    if OffsetDateTime::now_utc() > challenge_expiry {
        return Err(StoreError::InvitationExpired.into());
    }

    // Require proof from the same P-256 key bound to the challenge, not an arbitrary key supplied with the claim.
    if request.platform != "ios" && request.platform != "ipados" && request.platform != "macos" {
        return Err(PairingError::InvalidInvitation(
            "platform must be ios|ipados|macos".into(),
        ));
    }
    let device_key = canonical_p256_key(&request.device_public_key_spki)?;
    match (
        invitation.recipient_device_id,
        invitation.recipient_public_key_fingerprint.as_deref(),
    ) {
        (None, None) => {}
        (Some(expected_id), Some(expected_fingerprint))
            if expected_id == request.device_id
                && expected_fingerprint == device_key.fingerprint => {}
        (Some(_), Some(_)) => {
            return Err(PairingError::ChallengeMismatch(
                "claim does not match the invitation recipient".into(),
            ));
        }
        _ => {
            return Err(PairingError::InvalidInvitation(
                "recipient binding is incomplete".into(),
            ));
        }
    }
    if !constant_time_equals(
        &device_key.fingerprint,
        &challenge.device_public_key_fingerprint,
    ) {
        return Err(PairingError::ChallengeMismatch(
            "the claimed device key is not the key this challenge was issued for".into(),
        ));
    }
    let presence_key = match (
        request.presence_public_key_spki.as_deref(),
        request.presence_key_signature.as_deref(),
    ) {
        (None, None) => None,
        (Some(encoded), Some(signature)) => {
            let key = canonical_p256_key(encoded)?;
            if key.canonical_point == device_key.canonical_point {
                return Err(PairingError::BadPublicKey(
                    "presence key must be distinct from the request-signing key".into(),
                ));
            }
            Some((key, signature))
        }
        _ => {
            return Err(PairingError::InvalidInvitation(
                "presence public key and presence signature must be supplied together".into(),
            ));
        }
    };
    let signed_bytes = match &presence_key {
        Some((key, _)) => spark_contracts::pairing_presence_canonical(
            &base64url_encode(&challenge.challenge),
            &request.invitation.invitation_id,
            &request.device_id,
            &identity.node_id(),
            &key.fingerprint,
        )
        .into_bytes(),
        None => [
            challenge.challenge.as_slice(),
            request.invitation.invitation_id.to_string().as_bytes(),
            request.device_id.to_string().as_bytes(),
            identity.node_id().to_string().as_bytes(),
        ]
        .concat(),
    };
    let signature_bytes = base64url_decode(&request.challenge_signature)?;
    let signature = P256Signature::from_slice(&signature_bytes)
        .map_err(|_| PairingError::BadDeviceSignature)?;
    use p256::ecdsa::signature::Verifier as _;
    device_key
        .verifying_key
        .verify(&signed_bytes, &signature)
        .map_err(|_| PairingError::BadDeviceSignature)?;
    if let Some((presence_key, presence_signature)) = &presence_key {
        let signature_bytes = base64url_decode(presence_signature)?;
        let signature = P256Signature::from_slice(&signature_bytes)
            .map_err(|_| PairingError::BadDeviceSignature)?;
        presence_key
            .verifying_key
            .verify(&signed_bytes, &signature)
            .map_err(|_| PairingError::BadDeviceSignature)?;
    }

    // Atomically grant and consume, or return the exact prior receipt without granting or auditing twice.
    let tx = conn.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
    let role = &invitation.role;
    if let Some(existing) = store::consumed_invitation_grant(&tx, &invitation.invitation_id)? {
        let submitted_payload = serde_json::to_string(invitation)?;
        let submitted_presence = presence_key
            .as_ref()
            .map(|(key, _)| key.fingerprint.as_str());
        if existing.invitation.signed_payload_json != submitted_payload
            || existing.device.id != request.device_id
            || existing.device.display_name != request.device_name
            || existing.device.platform != request.platform
            || existing.device.role != stored_device_role(role)
            || existing.public_key_fingerprint != device_key.fingerprint
            || existing.presence_key_fingerprint.as_deref() != submitted_presence
        {
            return Err(StoreError::InvitationUnavailable.into());
        }
        store::consume_challenge(&tx, &request.challenge_id)?;
        tx.commit()?;
        return Ok(ClaimResponse {
            device: DeviceGrant {
                id: existing.device.id,
                display_name: existing.device.display_name,
                platform: existing.device.platform,
                role: role.clone(),
                paired_at: existing.device.paired_at,
                last_seen_at: existing.device.last_seen_at,
                revoked: false,
            },
            authority_certificate: crate::crypto::base64_encode(
                &identity
                    .public
                    .verifying_key()
                    .expect("authority public key verified at identity load")
                    .to_bytes(),
            ),
            issued_at: rfc3339(OffsetDateTime::now_utc()),
            presence_key_fingerprint: existing.presence_key_fingerprint,
        });
    }
    if role == "owner" && store::has_owner(&tx)? {
        return Err(PairingError::OwnerAlreadyExists);
    }
    let device_id = request.device_id;
    let stored_role = stored_device_role(role);
    store::insert_device_with_presence_key(
        &tx,
        &device_id,
        &request.device_name,
        &request.platform,
        &device_key.canonical_spki,
        &device_key.fingerprint,
        stored_role,
        presence_key
            .as_ref()
            .map(|(key, _)| (key.canonical_spki.as_slice(), key.fingerprint.as_str())),
    )?;
    // A guest's authority comes from its grant, so bind it here or the device stays at the stored floor.
    if role == super::GUEST_ROLE {
        crate::guest::bind_grant_to_device(
            &tx,
            &request.invitation.invitation_id,
            &device_id,
            &clock.now_rfc3339(),
        )?;
    }
    store::consume_challenge(&tx, &request.challenge_id)?;
    store::consume_invitation(&tx, &request.invitation.invitation_id, &device_id)?;
    // Retire the installer administrator in the same transaction that grants the first owner.
    if role == "owner" {
        let retired = store::revoke_installer_grant_for(&tx, &request.invitation.invitation_id)?;
        if retired > 0 {
            tracing::info!(retired, "install-time administrator grant revoked");
        }
    }
    let resource = format!("device/{device_id}");
    crate::audit::append(
        &tx,
        clock,
        &crate::audit::AuditDraft {
            actor_device_id: Some(device_id),
            actor_role: Some(role),
            source_route: "/api/v1/pairing/claim",
            action: "pairing.invitation.claimed",
            resource: Some(&resource),
            result: "succeeded",
            operation_id: None,
            request_id: None,
            details: &serde_json::json!({}),
        },
    )?;
    tx.commit()?;

    let issued_at = rfc3339(OffsetDateTime::now_utc());
    Ok(ClaimResponse {
        device: DeviceGrant {
            id: device_id,
            display_name: request.device_name.clone(),
            platform: request.platform.clone(),
            role: role.clone(),
            paired_at: issued_at.clone(),
            last_seen_at: None,
            revoked: false,
        },
        authority_certificate: crate::crypto::base64_encode(
            &identity
                .public
                .verifying_key()
                .expect("authority public key verified at identity load")
                .to_bytes(),
        ),
        issued_at,
        presence_key_fingerprint: presence_key.map(|(key, _)| key.fingerprint),
    })
}
