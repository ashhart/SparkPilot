use super::*;

#[derive(serde::Deserialize)]
pub struct DisableRemoteBody {
    pub accepted_preview_digest: String,
}

pub async fn preview_disable_remote_access(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    idempotency: IdempotencyRequest,
) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    if principal.role != "owner" {
        append_refusal(
            &state,
            &principal,
            &idempotency,
            "/api/v1/remote/disable/preview",
            "remote.disable.preview",
            "ROLE_FORBIDDEN",
        )?;
        return Err(error_envelope(
            StatusCode::FORBIDDEN,
            "ROLE_FORBIDDEN",
            "remote access is owner-only",
        ));
    }
    let draft = remote_draft(&state, "remote.disable", "disabled").await?;
    let preview = state
        .previews
        .issue(&draft)
        .map_err(|_| internal_envelope("remote access review could not be issued"))?;
    Ok(Json(preview))
}

/// `POST /api/v1/remote/disable` — 202 with the durable operation.
pub async fn disable_remote_access(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    Extension(authenticated_request): Extension<AuthenticatedRequest>,
    idempotency: IdempotencyRequest,
    headers: HeaderMap,
    axum::Json(body): axum::Json<DisableRemoteBody>,
) -> Result<(StatusCode, Json<Value>), (StatusCode, Json<Value>)> {
    let Some(db) = &state.database else {
        return Err(internal_envelope("no database"));
    };
    if principal.role != "owner" {
        append_refusal(
            &state,
            &principal,
            &idempotency,
            DISABLE_ROUTE,
            "remote.disable",
            "ROLE_FORBIDDEN",
        )?;
        return Err(error_envelope(
            StatusCode::FORBIDDEN,
            "ROLE_FORBIDDEN",
            "remote access is owner-only",
        ));
    }
    let Some(remote) = &state.remote else {
        return Err(internal_envelope("remote access service unavailable"));
    };

    let replay = {
        let _admission = state.idempotency.admission_guard();
        let mut connection = db.lock();
        state
            .idempotency
            .lookup(&mut connection, &idempotency)
            .map_err(|error| error.envelope())?
    };
    if let Some(outcome) = replay {
        return Ok(json_response(&outcome));
    }

    let draft = remote_draft(&state, "remote.disable", "disabled").await?;
    state
        .previews
        .validate(
            Some(&body.accepted_preview_digest),
            &draft,
            &format!("{}:{}", idempotency.device_id, idempotency.key),
        )
        .map_err(|error| error.envelope())?;

    let presence_key = presence_key(&state, &principal)?;
    if let Err(error) = crate::user_presence::verify(
        headers.get(crate::user_presence::HEADER_USER_PRESENCE),
        presence_key.as_deref(),
        &authenticated_request,
        state.clock.now(),
    ) {
        append_refusal(
            &state,
            &principal,
            &idempotency,
            DISABLE_ROUTE,
            "remote.disable",
            error.code(),
        )?;
        return Err(error_envelope(
            StatusCode::FORBIDDEN,
            error.code(),
            "fresh user presence is required to disable remote access",
        ));
    }

    let outcome = {
        let _admission = state.idempotency.admission_guard();
        let mut conn = db.lock();
        let details = json!({});
        state
            .idempotency
            .create_operation_audited(
                &mut conn,
                &idempotency,
                &state.jobs,
                "remote.disable",
                None,
                &json!({}).to_string(),
                &principal.role,
                DISABLE_ROUTE,
                Some(REMOTE_RESOURCE),
                &details,
            )
            .map_err(|error| error.envelope())?
    };
    if !outcome.created {
        return Ok(json_response(&outcome));
    }
    let operation_id = outcome.response.operation_id.unwrap();

    let remote = remote.clone();
    let worker_db = db.clone();
    state
        .jobs
        .spawn_leased(worker_db, operation_id, move |lease| {
            let outcome = remote.disable();
            match outcome {
                Ok(_) => {
                    if let Err(error) = lease.succeed(&json!({ "disabled": true })) {
                        tracing::error!(
                            operation_id = %operation_id,
                            error = %error,
                            "could not persist remote disable success"
                        );
                    }
                }
                Err(_) => {
                    if let Err(error) = lease.fail("REMOTE_DISABLE_FAILED") {
                        tracing::error!(
                            operation_id = %operation_id,
                            error = %error,
                            "could not persist remote disable failure"
                        );
                    }
                }
            }
        })
        .map_err(|error| crate::api_error::spawn_envelope(&error))?;

    Ok(json_response(&outcome))
}
