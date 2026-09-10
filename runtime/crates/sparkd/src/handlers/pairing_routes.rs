use super::*;

pub(super) fn pairing_error_response(error: PairingError) -> (StatusCode, Json<Value>) {
    use PairingError::*;
    let (status, code) = match &error {
        Store(StoreError::NotFound(_)) => (StatusCode::NOT_FOUND, "OPERATION_NOT_FOUND"),
        Store(StoreError::InvitationExpired) => (StatusCode::GONE, "INVITATION_EXPIRED"),
        Store(StoreError::InvitationUnavailable) => {
            (StatusCode::CONFLICT, "INVITATION_ALREADY_USED")
        }
        Store(StoreError::OwnerAlreadyExists) | OwnerAlreadyExists => {
            (StatusCode::CONFLICT, "ROLE_FORBIDDEN")
        }
        BadDeviceSignature => (StatusCode::UNAUTHORIZED, "SIGNATURE_INVALID"),
        RoleMismatch(_) => (StatusCode::FORBIDDEN, "ROLE_FORBIDDEN"),
        ChallengeMismatch(_) => (StatusCode::CONFLICT, "SIGNATURE_INVALID"),
        InvalidInvitation(_) => (StatusCode::UNPROCESSABLE_ENTITY, "INVALID_REQUEST"),
        InvalidJoinCode => (StatusCode::NOT_FOUND, "JOIN_CODE_INVALID"),
        TooManyJoinCodeAttempts { .. } => (StatusCode::TOO_MANY_REQUESTS, "RATE_LIMITED"),
        BadPublicKey(_) => (StatusCode::UNPROCESSABLE_ENTITY, "SIGNATURE_INVALID"),
        Json(_) => (StatusCode::UNPROCESSABLE_ENTITY, "INVALID_REQUEST"),
        Store(StoreError::Audit(_)) => (StatusCode::SERVICE_UNAVAILABLE, "AUDIT_UNAVAILABLE"),
        Store(StoreError::Sqlite(_)) | Sqlite(_) | Time(_) => {
            (StatusCode::INTERNAL_SERVER_ERROR, "INTERNAL_ERROR")
        }
    };
    (
        status,
        error_envelope(code, &uuid::Uuid::new_v4().to_string()),
    )
}

/// Issue pairing challenges only within valid invitations.
pub async fn pairing_challenge(
    State(state): State<AppState>,
    Json(request): Json<ChallengeRequest>,
) -> HandlerResult<Json<pairing::ChallengeResponse>> {
    let guard = state.database.as_ref().ok_or(internal_error())?.lock();
    let challenge = pairing::create_challenge(&guard, &state.identity, &request)
        .map_err(pairing_error_response)?;
    Ok(Json(challenge))
}

/// Claim an invitation once with a registered device key.
pub async fn pairing_claim(
    State(state): State<AppState>,
    Json(request): Json<ClaimRequest>,
) -> HandlerResult<(StatusCode, Json<pairing::ClaimResponse>)> {
    let mut guard = state.database.as_ref().ok_or(internal_error())?.lock();
    match pairing::claim_invitation(&mut guard, &state.identity, state.clock.as_ref(), &request) {
        Ok(claim) => {
            // §15.4 step 10: announce the grant to administrators without publishing any key material.
            state.events.emit_scoped(
                Some(&guard),
                &state.identity.node_id().to_string(),
                None,
                "device.paired",
                "notice",
                json!({
                    "device_id": claim.device.id,
                    "platform": claim.device.platform,
                    "role": claim.device.role,
                }),
                crate::events::Visibility::min_role(crate::capability::Role::Administrator),
            );
            Ok((StatusCode::CREATED, Json(claim)))
        }
        Err(error) => {
            let response = pairing_error_response(error);
            let auditable = pairing::claim_refusal_is_auditable(
                &guard,
                &state.identity,
                state.clock.now(),
                &request,
            )
            .unwrap_or(false);
            if !auditable {
                return Err(response);
            }
            let reason = crate::audit::response_code(&response, "PAIRING_CLAIM_FAILED");
            drop(guard);
            crate::audit::append_committed(
                state.database.as_ref().ok_or_else(internal_error)?,
                state.clock.as_ref(),
                &crate::audit::AuditDraft {
                    actor_device_id: None,
                    actor_role: None,
                    source_route: "/api/v1/pairing/claim",
                    action: "pairing.invitation.claimed",
                    resource: None,
                    result: "refused",
                    operation_id: None,
                    request_id: None,
                    details: &json!({ "reason_code": reason }),
                },
            )
            .map_err(crate::audit::unavailable_envelope)?;
            Err(response)
        }
    }
}

#[derive(Debug, serde::Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RedeemJoinCodeRequest {
    pub code: String,
}

#[derive(Debug, serde::Serialize)]
#[serde(rename_all = "snake_case")]
pub struct PairingJoinPackage {
    pub node_name: String,
    pub tls_fingerprint: String,
    pub authority_public_key: String,
    pub invitation: pairing::InvitationPayload,
}

/// Exchange a short, one-use join code for the existing signed trust package.
pub async fn redeem_join_code(
    State(state): State<AppState>,
    Json(request): Json<RedeemJoinCodeRequest>,
) -> HandlerResult<Json<PairingJoinPackage>> {
    let tls_fingerprint = state.tls_fingerprint.clone().ok_or_else(|| {
        (
            StatusCode::SERVICE_UNAVAILABLE,
            error_envelope(
                "PAIRING_TRUST_UNAVAILABLE",
                &uuid::Uuid::new_v4().to_string(),
            ),
        )
    })?;
    let guard = state.database.as_ref().ok_or(internal_error())?.lock();
    let invitation = match pairing::redeem_join_code(&guard, &request.code) {
        Ok(invitation) => invitation,
        Err(PairingError::TooManyJoinCodeAttempts {
            retry_after_seconds,
        }) => {
            let (status, mut envelope) =
                pairing_error_response(PairingError::TooManyJoinCodeAttempts {
                    retry_after_seconds,
                });
            envelope.0["error"]["details"] = json!({ "retry_after_seconds": retry_after_seconds });
            return Err((status, envelope));
        }
        Err(error) => {
            // Tell administrators the moment the guessing budget is spent, because the lockout also blocks legitimate joins.
            if matches!(error, PairingError::InvalidJoinCode)
                && pairing::join_code_failures_in_window(&guard).unwrap_or(0)
                    == pairing::MAX_FAILED_JOIN_CODES
            {
                state.events.emit_scoped(
                    Some(&guard),
                    &state.identity.node_id().to_string(),
                    None,
                    "security.join_code.locked",
                    "warning",
                    json!({
                        "failures": pairing::MAX_FAILED_JOIN_CODES,
                        "window_minutes": pairing::JOIN_CODE_FAILURE_WINDOW_MINUTES,
                    }),
                    crate::events::Visibility::min_role(crate::capability::Role::Administrator),
                );
            }
            return Err(pairing_error_response(error));
        }
    };
    Ok(Json(PairingJoinPackage {
        node_name: state.identity.public.node_name.clone(),
        tls_fingerprint,
        authority_public_key: state.identity.public.authority_public_key.clone(),
        invitation,
    }))
}

/// Issue a single-use nonce for the enrolled presence key; the node verifies freshness and key possession, not the platform biometric result.
pub async fn presence_challenge(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
) -> HandlerResult<(StatusCode, Json<Value>)> {
    let guard = state.database.as_ref().ok_or(internal_error())?.lock();
    let issued = crate::presence::issue(
        &guard,
        state.clock.as_ref(),
        &principal.device_id,
        state.presence_freshness_seconds,
    )
    .map_err(|error| {
        tracing::error!(%error, "presence challenge could not be issued");
        internal_error()
    })?;
    Ok((
        StatusCode::CREATED,
        Json(serde_json::to_value(issued).unwrap_or_default()),
    ))
}

/// Issue administrator or owner-authorized pairing invitations.
pub async fn create_invitation(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    Extension(authenticated_request): Extension<AuthenticatedRequest>,
    headers: HeaderMap,
    idempotency: IdempotencyRequest,
    Json(request): Json<CreateInvitationRequest>,
) -> HandlerResult<(StatusCode, Json<Value>)> {
    let recipient = match (
        request.recipient_device_id,
        request.recipient_public_key_fingerprint.clone(),
    ) {
        (None, None) => None,
        (Some(device_id), Some(fingerprint)) => Some((device_id, fingerprint)),
        _ => {
            return Err(unprocessable(
                "INVALID_REQUEST",
                "recipient device id and public-key fingerprint must be supplied together",
            ));
        }
    };
    let requested_role = crate::capability::Role::parse(&request.role);
    let authorization = || {
        state
            .require(&principal, crate::capability::Capability::DevicePair)
            .on_device(requested_role)
            .resource("pairing/invitations")
            .details(json!({ "requested_role": request.role }))
    };
    let append_invitation_refusal = |reason: &str| {
        crate::audit::append_refusal(
            state.database.as_ref().ok_or_else(internal_error)?,
            state.clock.as_ref(),
            principal.device_id,
            &principal.role,
            "/api/v1/pairing/invitations",
            "pairing.invitation.created",
            None,
            idempotency.request_id,
            reason,
        )
        .map_err(crate::audit::unavailable_envelope)
    };
    // Reject insufficient nonowner authority before requesting or consuming presence.
    let mut authorization_checked = false;
    if principal.role != "owner" {
        match authorization().check_with_verified_presence(crate::capability::Presence::Absent) {
            Ok(()) => authorization_checked = true,
            Err(denial) if denial.0 == StatusCode::FORBIDDEN => {
                let reason = crate::audit::response_code(&denial, "ROLE_FORBIDDEN");
                append_invitation_refusal(&reason)?;
                return Err(denial);
            }
            Err(failure) => return Err(failure),
        }
    }
    // Require fresh presence for both privileged invitation issuance and replay because each retrieval discloses a live bearer capability.
    let presence = if matches!(request.role.as_str(), "administrator" | "owner") {
        let presence_key = {
            let guard = state.database.as_ref().ok_or(internal_error())?.lock();
            crate::store::load_presence_key_by_device_id(&guard, &principal.device_id)
                .map_err(|error| pairing_error_response(PairingError::Store(error)))?
        };
        if let Err(error) = crate::user_presence::verify(
            headers.get(crate::user_presence::HEADER_USER_PRESENCE),
            presence_key.as_deref(),
            &authenticated_request,
            state.clock.now(),
        ) {
            match authorization().check_with_verified_presence(crate::capability::Presence::Absent)
            {
                Err(denial) if denial.0 == StatusCode::FORBIDDEN => {}
                Err(failure) => return Err(failure),
                Ok(()) => return Err(internal_error()),
            }
            append_invitation_refusal(error.code())?;
            return Err((
                StatusCode::FORBIDDEN,
                error_envelope(error.code(), &uuid::Uuid::new_v4().to_string()),
            ));
        }
        crate::capability::Presence::Fresh
    } else {
        crate::capability::Presence::Absent
    };
    if !authorization_checked {
        authorization().check_with_verified_presence(presence)?;
    }
    let mut guard = state.database.as_ref().ok_or(internal_error())?.lock();
    let outcome = state
        .idempotency
        .execute(&mut guard, &idempotency, |transaction| {
            match pairing::issue_invitation_for_recipient(
                transaction,
                &state.identity,
                &principal.device_id,
                request.role,
                request.expires_in_seconds,
                request.device_name_hint,
                recipient,
            ) {
                Ok(issued) => {
                    let resource = format!("pairing-invitation/{}", issued.payload.invitation_id);
                    let details = json!({ "role": issued.payload.role.clone() });
                    crate::audit::append(
                        transaction,
                        state.clock.as_ref(),
                        &crate::audit::AuditDraft {
                            actor_device_id: Some(principal.device_id),
                            actor_role: Some(&principal.role),
                            source_route: "/api/v1/pairing/invitations",
                            action: "pairing.invitation.created",
                            resource: Some(&resource),
                            result: "succeeded",
                            operation_id: None,
                            request_id: idempotency.request_id,
                            details: &details,
                        },
                    )?;
                    let mut body = serde_json::to_value(&issued.payload).unwrap_or_default();
                    body["join_code"] = json!(issued.join_code);
                    Ok(StoredResponse {
                        status: StatusCode::CREATED,
                        body,
                        operation_id: None,
                    })
                }
                Err(error) => {
                    let (status, Json(body)) = pairing_error_response(error);
                    let reason = body
                        .get("error")
                        .and_then(|error| error.get("code"))
                        .and_then(Value::as_str)
                        .unwrap_or("PAIRING_INVITATION_FAILED");
                    crate::audit::append(
                        transaction,
                        state.clock.as_ref(),
                        &crate::audit::AuditDraft {
                            actor_device_id: Some(principal.device_id),
                            actor_role: Some(&principal.role),
                            source_route: "/api/v1/pairing/invitations",
                            action: "pairing.invitation.created",
                            resource: None,
                            result: "refused",
                            operation_id: None,
                            request_id: idempotency.request_id,
                            details: &json!({ "reason_code": reason }),
                        },
                    )?;
                    Ok(StoredResponse {
                        status,
                        body,
                        operation_id: None,
                    })
                }
            }
        })
        .map_err(|error| error.envelope())?;
    if outcome.response.status.is_success() {
        Ok(json_response(&outcome))
    } else {
        Err(json_response(&outcome))
    }
}

#[derive(Debug, serde::Deserialize)]
#[serde(rename_all = "snake_case")]
pub struct CreateInvitationRequest {
    pub role: String,
    #[serde(default)]
    pub expires_in_seconds: Option<i64>,
    #[serde(default)]
    pub device_name_hint: Option<String>,
    #[serde(default)]
    pub recipient_device_id: Option<uuid::Uuid>,
    #[serde(default)]
    pub recipient_public_key_fingerprint: Option<String>,
}
