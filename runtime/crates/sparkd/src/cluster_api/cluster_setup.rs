use super::*;

pub(super) fn append_create_refusal(
    state: &AppState,
    principal: &Principal,
    idempotency: &IdempotencyRequest,
    reason_code: &str,
) -> Result<(), (StatusCode, Json<Value>)> {
    crate::audit::append_refusal(
        state
            .database
            .as_ref()
            .ok_or_else(|| internal_envelope("no database"))?,
        state.clock.as_ref(),
        principal.device_id,
        &principal.role,
        CREATE_ROUTE,
        "cluster.create",
        Some(CLUSTER_RESOURCE),
        idempotency.request_id,
        reason_code,
    )
    .map(|_| ())
    .map_err(crate::audit::unavailable_envelope)
}

pub(super) fn append_validate_refusal(
    state: &AppState,
    principal: &Principal,
    idempotency: &IdempotencyRequest,
    reason_code: &str,
) -> Result<(), (StatusCode, Json<Value>)> {
    crate::audit::append_refusal(
        state
            .database
            .as_ref()
            .ok_or_else(|| internal_envelope("no database"))?,
        state.clock.as_ref(),
        principal.device_id,
        &principal.role,
        VALIDATE_ROUTE,
        "cluster.validate",
        Some(CLUSTER_RESOURCE),
        idempotency.request_id,
        reason_code,
    )
    .map(|_| ())
    .map_err(crate::audit::unavailable_envelope)
}

#[derive(serde::Deserialize, serde::Serialize)]
pub struct CreateClusterBody {
    pub name: String,
    pub member_node_ids: Vec<String>,
}

/// Create a cluster through a durable operation.
pub async fn create_cluster(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    Extension(authenticated_request): Extension<AuthenticatedRequest>,
    idempotency: IdempotencyRequest,
    headers: HeaderMap,
    axum::Json(body): axum::Json<CreateClusterBody>,
) -> Result<(StatusCode, Json<Value>), (StatusCode, Json<Value>)> {
    if principal.role != "owner" {
        append_create_refusal(&state, &principal, &idempotency, "ROLE_FORBIDDEN")?;
        return Err(cluster_envelope(
            "ROLE_FORBIDDEN",
            "cluster creation is owner-only",
            StatusCode::FORBIDDEN,
        ));
    }
    let Some(cluster) = &state.cluster else {
        return Err(internal_envelope("cluster service unavailable"));
    };
    let Some(db) = &state.database else {
        return Err(internal_envelope("no database"));
    };

    if state.cluster_coordination.is_some() {
        append_create_refusal(
            &state,
            &principal,
            &idempotency,
            "CLUSTER_TRANSACTION_REQUIRED",
        )?;
        return Err(cluster_envelope(
            "CLUSTER_TRANSACTION_REQUIRED",
            "managed clusters must use the two-sided signed transaction flow",
            StatusCode::CONFLICT,
        ));
    }

    // Refuse incomplete coordination before consuming presence, idempotency or operation state.
    if !cluster.management_available() {
        append_create_refusal(
            &state,
            &principal,
            &idempotency,
            "CLUSTER_MANAGEMENT_UNAVAILABLE",
        )?;
        return Err(cluster_envelope(
            "CLUSTER_MANAGEMENT_UNAVAILABLE",
            "this build has no production cluster coordinator, so cluster changes are unavailable",
            StatusCode::SERVICE_UNAVAILABLE,
        ));
    }

    let _admission = state.idempotency.admission_guard();
    let replay = {
        let mut connection = db.lock();
        state
            .idempotency
            .lookup(&mut connection, &idempotency)
            .map_err(|error| error.envelope())?
    };
    if let Some(outcome) = replay {
        return Ok(json_response(&outcome));
    }

    if body.member_node_ids.len() < 2 {
        append_create_refusal(&state, &principal, &idempotency, "MEMBERSHIP_TOO_SMALL")?;
        return Err(cluster_envelope(
            "MEMBERSHIP_TOO_SMALL",
            "clusters require at least two members",
            StatusCode::UNPROCESSABLE_ENTITY,
        ));
    }
    let unique_members = body
        .member_node_ids
        .iter()
        .collect::<std::collections::HashSet<_>>();
    if unique_members.len() != body.member_node_ids.len() {
        append_create_refusal(&state, &principal, &idempotency, "MEMBERSHIP_DUPLICATE")?;
        return Err(cluster_envelope(
            "MEMBERSHIP_DUPLICATE",
            "cluster members must be distinct",
            StatusCode::UNPROCESSABLE_ENTITY,
        ));
    }

    let presence_key = presence_key(&state, &principal)?;
    if let Err(error) = crate::user_presence::verify(
        headers.get(crate::user_presence::HEADER_USER_PRESENCE),
        presence_key.as_deref(),
        &authenticated_request,
        state.clock.now(),
    ) {
        append_create_refusal(&state, &principal, &idempotency, error.code())?;
        return Err(cluster_envelope(
            error.code(),
            "fresh user presence is required to create a cluster",
            StatusCode::FORBIDDEN,
        ));
    }

    let request_json =
        serde_json::to_string(&body).map_err(|error| internal_envelope(&error.to_string()))?;
    let outcome = {
        let mut conn = db.lock();
        let audit_details = json!({ "member_count": body.member_node_ids.len() });
        state
            .idempotency
            .create_operation_audited(
                &mut conn,
                &idempotency,
                &state.jobs,
                "cluster.create",
                None,
                &request_json,
                &principal.role,
                CREATE_ROUTE,
                Some(CLUSTER_RESOURCE),
                &audit_details,
            )
            .map_err(|error| error.envelope())?
    };
    if !outcome.created {
        return Ok(json_response(&outcome));
    }
    let operation_id = outcome.response.operation_id.unwrap();

    let cluster = cluster.clone();
    let worker_db = db.clone();
    let facts_db = db.clone();
    let name = body.name.clone();
    let member_node_ids = body.member_node_ids.clone();
    state
        .jobs
        .spawn_leased(worker_db, operation_id, move |lease| {
            // Accept only node IDs publicly and resolve compatibility facts from authenticated peer records inside the worker.
            let facts = {
                let conn = facts_db.lock();
                crate::cluster::resolve_cluster_member_facts(&conn, &member_node_ids).map(|facts| {
                    facts
                        .into_iter()
                        .map(Into::into)
                        .collect::<Vec<crate::cluster::MemberFacts>>()
                })
            };
            let outcome = facts.and_then(|facts| cluster.create(&name, &facts));
            match outcome {
                Ok(_) => {
                    if let Err(error) = lease.succeed(&json!({ "created": true })) {
                        tracing::error!(
                            operation_id = %operation_id,
                            error = %error,
                            "could not persist cluster creation success"
                        );
                    }
                }
                Err(_) => {
                    if let Err(error) = lease.fail("CLUSTER_CREATE_FAILED") {
                        tracing::error!(
                            operation_id = %operation_id,
                            error = %error,
                            "could not persist cluster creation failure"
                        );
                    }
                }
            }
        })
        .map_err(|error| crate::api_error::spawn_envelope(&error))?;

    Ok(json_response(&outcome))
}

/// Validate current cluster readiness.
pub async fn validate_cluster(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    Extension(authenticated_request): Extension<AuthenticatedRequest>,
    idempotency: IdempotencyRequest,
    headers: HeaderMap,
) -> Result<(StatusCode, Json<Value>), (StatusCode, Json<Value>)> {
    if !principal.is_admin() {
        append_validate_refusal(&state, &principal, &idempotency, "ROLE_FORBIDDEN")?;
        return Err(cluster_envelope(
            "ROLE_FORBIDDEN",
            "cluster validation is admin-only",
            StatusCode::FORBIDDEN,
        ));
    }
    let Some(cluster) = &state.cluster else {
        return Err(internal_envelope("cluster service unavailable"));
    };
    let Some(db) = &state.database else {
        return Err(internal_envelope("no database"));
    };

    if state.cluster_coordination.is_some() {
        append_validate_refusal(
            &state,
            &principal,
            &idempotency,
            "CLUSTER_TRANSACTION_REQUIRED",
        )?;
        return Err(cluster_envelope(
            "CLUSTER_TRANSACTION_REQUIRED",
            "managed cluster validation is part of the two-sided signed transaction flow",
            StatusCode::CONFLICT,
        ));
    }

    if !cluster.management_available() {
        append_validate_refusal(
            &state,
            &principal,
            &idempotency,
            "CLUSTER_MANAGEMENT_UNAVAILABLE",
        )?;
        return Err(cluster_envelope(
            "CLUSTER_MANAGEMENT_UNAVAILABLE",
            "this build has no production cluster coordinator, so cluster changes are unavailable",
            StatusCode::SERVICE_UNAVAILABLE,
        ));
    }

    let _admission = state.idempotency.admission_guard();
    let replay = {
        let mut connection = db.lock();
        state
            .idempotency
            .lookup(&mut connection, &idempotency)
            .map_err(|error| error.envelope())?
    };
    if let Some(outcome) = replay {
        return Ok(json_response(&outcome));
    }

    let presence_key = presence_key(&state, &principal)?;
    if let Err(error) = crate::user_presence::verify(
        headers.get(crate::user_presence::HEADER_USER_PRESENCE),
        presence_key.as_deref(),
        &authenticated_request,
        state.clock.now(),
    ) {
        append_validate_refusal(&state, &principal, &idempotency, error.code())?;
        return Err(cluster_envelope(
            error.code(),
            "fresh user presence is required to validate a cluster",
            StatusCode::FORBIDDEN,
        ));
    }

    let outcome = {
        let mut conn = db.lock();
        state
            .idempotency
            .create_operation_audited(
                &mut conn,
                &idempotency,
                &state.jobs,
                "cluster.validate",
                None,
                &json!({}).to_string(),
                &principal.role,
                VALIDATE_ROUTE,
                Some(CLUSTER_RESOURCE),
                &json!({}),
            )
            .map_err(|error| error.envelope())?
    };
    if !outcome.created {
        return Ok(json_response(&outcome));
    }
    let operation_id = outcome.response.operation_id.unwrap();

    let cluster = cluster.clone();
    let worker_db = db.clone();
    state
        .jobs
        .spawn_leased(worker_db, operation_id, move |lease| {
            let outcome = cluster.validate();
            match outcome {
                Ok(row) => {
                    if let Err(error) = lease.succeed(&json!({ "state": row.state })) {
                        tracing::error!(
                            operation_id = %operation_id,
                            error = %error,
                            "could not persist cluster validation success"
                        );
                    }
                }
                Err(_) => {
                    if let Err(error) = lease.fail("CLUSTER_VALIDATE_FAILED") {
                        tracing::error!(
                            operation_id = %operation_id,
                            error = %error,
                            "could not persist cluster validation failure"
                        );
                    }
                }
            }
        })
        .map_err(|error| crate::api_error::spawn_envelope(&error))?;

    Ok(json_response(&outcome))
}
