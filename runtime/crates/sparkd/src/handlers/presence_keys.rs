use super::*;

#[derive(Debug, serde::Deserialize)]
#[serde(rename_all = "snake_case", deny_unknown_fields)]
pub struct EnrollPresenceKeyRequest {
    pub presence_public_key_spki: String,
}

/// Enroll a presence key once for the already-paired calling device.
pub async fn enroll_presence_key(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    Extension(authenticated_request): Extension<AuthenticatedRequest>,
    idempotency: IdempotencyRequest,
    headers: HeaderMap,
    Json(request): Json<EnrollPresenceKeyRequest>,
) -> HandlerResult<(StatusCode, Json<Value>)> {
    let database = state.database.as_ref().ok_or(internal_error())?;
    let resource = format!("device/{}", principal.device_id);
    let refuse = |response: (StatusCode, Json<Value>)| {
        let reason = crate::audit::response_code(&response, "PRESENCE_KEY_ENROLLMENT_FAILED");
        match crate::audit::append_refusal(
            database,
            state.clock.as_ref(),
            principal.device_id,
            &principal.role,
            "/api/v1/devices/self/presence-key",
            "device.presence_key.enroll",
            Some(&resource),
            idempotency.request_id,
            &reason,
        ) {
            Ok(_) => response,
            Err(error) => crate::audit::unavailable_envelope(error),
        }
    };
    let proposed = pairing::canonical_p256_key(&request.presence_public_key_spki)
        .map_err(pairing_error_response)
        .map_err(&refuse)?;
    let stored_device = {
        let guard = database.lock();
        crate::store::load_device_by_id(&guard, &principal.device_id)
    };
    let device = match stored_device {
        Ok(Some(device)) => device,
        Ok(None) => {
            return Err(refuse(pairing_error_response(PairingError::Store(
                StoreError::NotFound("device"),
            ))));
        }
        Err(error) => {
            return Err(refuse(pairing_error_response(PairingError::Store(error))));
        }
    };
    let request_key = pairing::canonical_p256_key_der(&device.public_key_spki)
        .map_err(pairing_error_response)
        .map_err(&refuse)?;
    if proposed.canonical_point == request_key.canonical_point {
        return Err(refuse(pairing_error_response(PairingError::BadPublicKey(
            "presence key must be distinct from the request-signing key".into(),
        ))));
    }
    let proof = headers
        .get(crate::user_presence::HEADER_PRESENCE_KEY_PROOF)
        .and_then(|value| value.to_str().ok())
        .filter(|value| value.len() == 86)
        .ok_or_else(|| {
            refuse((
                StatusCode::FORBIDDEN,
                error_envelope("USER_PRESENCE_INVALID", &uuid::Uuid::new_v4().to_string()),
            ))
        })?;
    let proof = crate::crypto::base64url_decode(proof).map_err(|_| {
        refuse((
            StatusCode::FORBIDDEN,
            error_envelope("USER_PRESENCE_INVALID", &uuid::Uuid::new_v4().to_string()),
        ))
    })?;
    let proof = p256::ecdsa::Signature::from_slice(&proof).map_err(|_| {
        refuse((
            StatusCode::FORBIDDEN,
            error_envelope("USER_PRESENCE_INVALID", &uuid::Uuid::new_v4().to_string()),
        ))
    })?;
    let canonical = spark_contracts::presence_enrollment_canonical(
        &authenticated_request.method,
        &authenticated_request.path_and_query,
        &authenticated_request.timestamp,
        &authenticated_request.nonce,
        &authenticated_request.content_sha256,
        &principal.device_id,
        &proposed.fingerprint,
        &authenticated_request.node_id,
    );
    proposed
        .verifying_key
        .verify(canonical.as_bytes(), &proof)
        .map_err(|_| {
            refuse((
                StatusCode::FORBIDDEN,
                error_envelope("USER_PRESENCE_INVALID", &uuid::Uuid::new_v4().to_string()),
            ))
        })?;

    let fingerprint = proposed.fingerprint.clone();
    let mut guard = database.lock();
    let outcome = state
        .idempotency
        .execute(&mut guard, &idempotency, |transaction| {
            crate::audit::append(
                transaction,
                state.clock.as_ref(),
                &crate::audit::AuditDraft {
                    actor_device_id: Some(principal.device_id),
                    actor_role: Some(&principal.role),
                    source_route: "/api/v1/devices/self/presence-key",
                    action: "device.presence_key.enroll",
                    resource: Some(&resource),
                    result: "accepted",
                    operation_id: None,
                    request_id: idempotency.request_id,
                    details: &json!({}),
                },
            )?;
            let enrollment = crate::store::enroll_presence_key(
                transaction,
                &principal.device_id,
                &proposed.canonical_spki,
                &proposed.fingerprint,
            );
            match enrollment {
                Ok(
                    crate::store::PresenceKeyEnrollment::Enrolled
                    | crate::store::PresenceKeyEnrollment::AlreadyEnrolled,
                ) => {
                    crate::audit::append(
                        transaction,
                        state.clock.as_ref(),
                        &crate::audit::AuditDraft {
                            actor_device_id: Some(principal.device_id),
                            actor_role: Some(&principal.role),
                            source_route: "/api/v1/devices/self/presence-key",
                            action: "device.presence_key.enroll",
                            resource: Some(&resource),
                            result: "succeeded",
                            operation_id: None,
                            request_id: idempotency.request_id,
                            details: &json!({}),
                        },
                    )?;
                    Ok(StoredResponse {
                        status: StatusCode::OK,
                        body: json!({ "presence_key_fingerprint": fingerprint }),
                        operation_id: None,
                    })
                }
                Ok(crate::store::PresenceKeyEnrollment::Conflict) => {
                    crate::audit::append(
                        transaction,
                        state.clock.as_ref(),
                        &crate::audit::AuditDraft {
                            actor_device_id: Some(principal.device_id),
                            actor_role: Some(&principal.role),
                            source_route: "/api/v1/devices/self/presence-key",
                            action: "device.presence_key.enroll",
                            resource: Some(&resource),
                            result: "refused",
                            operation_id: None,
                            request_id: idempotency.request_id,
                            details: &json!({ "reason_code": "USER_PRESENCE_KEY_CONFLICT" }),
                        },
                    )?;
                    Ok(StoredResponse {
                        status: StatusCode::CONFLICT,
                        body: error_envelope(
                            "USER_PRESENCE_KEY_CONFLICT",
                            &uuid::Uuid::new_v4().to_string(),
                        )
                        .0,
                        operation_id: None,
                    })
                }
                Err(error) => {
                    let (status, Json(body)) = pairing_error_response(PairingError::Store(error));
                    let reason = body
                        .get("error")
                        .and_then(|error| error.get("code"))
                        .and_then(Value::as_str)
                        .unwrap_or("PRESENCE_KEY_ENROLLMENT_FAILED");
                    crate::audit::append(
                        transaction,
                        state.clock.as_ref(),
                        &crate::audit::AuditDraft {
                            actor_device_id: Some(principal.device_id),
                            actor_role: Some(&principal.role),
                            source_route: "/api/v1/devices/self/presence-key",
                            action: "device.presence_key.enroll",
                            resource: Some(&resource),
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
