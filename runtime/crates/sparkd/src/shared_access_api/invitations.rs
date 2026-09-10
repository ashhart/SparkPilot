use super::*;

/// What the owner sends to invite one friend: the limits, and how long the link should live.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "snake_case", deny_unknown_fields)]
pub struct CreateSharedAccessInvitation {
    #[serde(flatten)]
    pub limits: SharedAccessLimits,
    #[serde(default)]
    pub invitation_expires_in_seconds: Option<i64>,
}

/// Issue a signed, single-use shared-access invitation carrying the routes a friend needs.
pub async fn create_shared_access_invitation(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    Extension(authenticated): Extension<AuthenticatedRequest>,
    headers: HeaderMap,
    idempotency: IdempotencyRequest,
    Json(request): Json<CreateSharedAccessInvitation>,
) -> ApiResult<(StatusCode, Json<Value>)> {
    let policy = request.limits.policy(GrantState::Pending);
    validated(&policy)?;
    owner_with_presence(
        &state,
        &principal,
        &authenticated,
        &headers,
        "shared-access/invitations",
        json!({ "display_name": policy.display_name, "models": policy.allowed_models.len() }),
    )?;

    let routes = connection_routes(&state);
    let summary = crate::pairing::SharedAccessSummary {
        display_name: policy.display_name.clone(),
        allowed_models: policy.allowed_models.clone(),
        allowed_hours: policy.allowed_hours.days.clone(),
        time_zone: policy.time_zone.clone(),
        max_concurrent_requests: policy.max_concurrent_requests,
        daily_token_budget: policy.daily_token_budget,
        expires_at: policy.expires_at,
    };
    let database = state
        .database
        .as_ref()
        .ok_or_else(|| internal("no database"))?;
    let mut guard = database.lock();
    let transaction = guard
        .transaction()
        .map_err(|error| internal(&error.to_string()))?;
    let issued = crate::pairing::issue_guest_invitation(
        &transaction,
        &state.identity,
        &principal.device_id,
        summary,
        &routes,
        request.invitation_expires_in_seconds,
    )
    .map_err(|error| {
        envelope(
            "SHARED_ACCESS_POLICY_INVALID",
            &error.to_string(),
            StatusCode::UNPROCESSABLE_ENTITY,
        )
    })?;
    crate::guest::insert_grant(
        &transaction,
        &issued.payload.invitation_id,
        &principal.device_id,
        &policy,
        &state.clock.now_rfc3339(),
    )
    .map_err(|error| internal(&error.to_string()))?;
    let resource = format!("shared-access-invitation/{}", issued.payload.invitation_id);
    crate::audit::append(
        &transaction,
        state.clock.as_ref(),
        &crate::audit::AuditDraft {
            actor_device_id: Some(principal.device_id),
            actor_role: Some(&principal.role),
            source_route: "/api/v1/shared-access/invitations",
            action: "shared_access.invitation.created",
            resource: Some(&resource),
            result: "succeeded",
            operation_id: None,
            request_id: idempotency.request_id,
            details: &json!({ "display_name": policy.display_name }),
        },
    )
    .map_err(crate::audit::unavailable_envelope)?;
    transaction
        .commit()
        .map_err(|error| internal(&error.to_string()))?;
    drop(guard);

    let mut body = serde_json::to_value(&issued.payload).unwrap_or_default();
    body["join_code"] = json!(issued.join_code);
    Ok((
        StatusCode::CREATED,
        Json(json!({
            "invitation": body,
            "node_name": routes.node_name,
            "tls_fingerprint": routes.tls_fingerprint,
            "authority_public_key": state.identity.public.authority_public_key,
            "local_endpoint": routes.local_endpoint,
            "remote_endpoint": routes.remote_endpoint,
            "remote_hostname": routes.remote_hostname,
            "expires_at": issued.expires_at,
        })),
    ))
}

/// Gather the routes the friend will try: the local one always, the tailnet name when remote access is on.
fn connection_routes(state: &AppState) -> crate::pairing::InvitationRoutes {
    let port = state.config.listen.port();
    let node_name = state.identity.public.node_name.clone();
    let scheme = if state.config.tls { "https" } else { "http" };
    let local_endpoint = Some(format!(
        "{scheme}://{}.local:{port}",
        crate::bonjour::instance_label(&node_name, &state.identity.node_id().to_string())
    ));
    let remote = state
        .remote
        .as_ref()
        .and_then(|remote| remote.status().ok())
        .filter(|status| status.enabled);
    let remote_hostname = remote.as_ref().and_then(|status| status.hostname.clone());
    crate::pairing::InvitationRoutes {
        node_name,
        tls_fingerprint: state.tls_fingerprint.clone(),
        local_endpoint,
        remote_endpoint: remote_hostname
            .as_ref()
            .map(|hostname| format!("{scheme}://{hostname}:{port}")),
        remote_hostname,
    }
}
