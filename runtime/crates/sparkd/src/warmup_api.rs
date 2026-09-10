//! Owner-reviewed, device-signed scheduling; no client timer drives execution.
use crate::auth::{AuthenticatedRequest, Principal};
use crate::idempotency::{IdempotencyRequest, StoredResponse, json_response};
use crate::preview::{PreviewDraft, PreviewMessage};
use crate::state::AppState;
use crate::warmup::{self, WarmupPin};
use axum::{
    Json,
    extract::{Extension, Path, State},
    http::{HeaderMap, StatusCode},
};
use serde::Deserialize;
use serde_json::{Value, json};
use uuid::Uuid;

type Failure = (StatusCode, Json<Value>);
const ROUTE: &str = "/api/v1/inference/warmups";
#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct WarmupRequest {
    pub model_id: String,
    pub profile_id: String,
    /// Absolute Unix seconds, interpreted on the Spark's clock.
    pub due_at: i64,
    pub accepted_preview_digest: Option<String>,
}
pub(crate) fn error(status: StatusCode, code: &str, message: &str) -> Failure {
    (
        status,
        Json(
            json!({"error":{"code":code,"message":message,"request_id":crate::route::current_request_id()}}),
        ),
    )
}
fn internal(error: impl std::fmt::Display) -> Failure {
    crate::models::internal_envelope(&error.to_string())
}
fn owner(state: &AppState, principal: &Principal) -> Result<(), Failure> {
    if principal.role == "owner" {
        return Ok(());
    }
    if let Some(database) = &state.database {
        crate::audit::append_refusal(
            database,
            state.clock.as_ref(),
            principal.device_id,
            &principal.role,
            ROUTE,
            "warmup.manage",
            None,
            None,
            "ROLE_FORBIDDEN",
        )
        .map_err(crate::audit::unavailable_envelope)?;
    }
    Err(error(
        StatusCode::FORBIDDEN,
        "ROLE_FORBIDDEN",
        "Only an owner can delegate a future model load.",
    ))
}
fn presence(
    state: &AppState,
    principal: &Principal,
    request: &AuthenticatedRequest,
    headers: &HeaderMap,
) -> Result<(), Failure> {
    let database = state
        .database
        .as_ref()
        .ok_or_else(|| internal("database unavailable"))?;
    let key = crate::store::load_presence_key_by_device_id(&database.lock(), &principal.device_id)
        .map_err(internal)?;
    crate::user_presence::verify(
        headers.get(crate::user_presence::HEADER_USER_PRESENCE),
        key.as_deref(),
        request,
        state.clock.now(),
    )
    .map_err(|failure| {
        match crate::audit::append_refusal(
            database,
            state.clock.as_ref(),
            principal.device_id,
            &principal.role,
            ROUTE,
            "warmup.manage",
            None,
            None,
            failure.code(),
        ) {
            Ok(_) => error(
                StatusCode::FORBIDDEN,
                failure.code(),
                "Fresh user presence is required to schedule or disable a warm-up.",
            ),
            Err(failure) => crate::audit::unavailable_envelope(failure),
        }
    })
}
pub(crate) async fn live_draft(
    state: &AppState,
    model_id: &str,
    profile_id: &str,
) -> Result<(PreviewDraft, spark_models::ModelRecipe), Failure> {
    let manager = state
        .engine
        .manager
        .clone()
        .ok_or_else(|| internal("engine unavailable"))?;
    let container = tokio::task::spawn_blocking(move || manager.container_runtime())
        .await
        .map_err(internal)?;
    let external = crate::workload_api::external_inference_guard(state).await;
    let (mut draft, recipe) = crate::engine_api::load_preview_draft(
        state,
        model_id,
        profile_id,
        false,
        None,
        Some(&container),
        external,
    )?;
    let verifier = state.catalogue_refresh.as_ref().ok_or_else(|| {
        error(
            StatusCode::SERVICE_UNAVAILABLE,
            "WARMUP_VERIFIER_UNAVAILABLE",
            "A trusted recipe authority must be configured before scheduling a model.",
        )
    })?;
    verifier.verify_recipe(&recipe).map_err(|_| {
        error(
            StatusCode::UNPROCESSABLE_ENTITY,
            "MODEL_RECIPE_UNTRUSTED",
            "Scheduled warm-up requires a currently trusted signed recipe.",
        )
    })?;
    if !draft.binding.evidence.cluster_membership_available {
        draft.blockers.push(PreviewMessage::blocker(
            "WARMUP_CLUSTER_STATE_UNKNOWN",
            "The Spark cannot prove that it is a standalone target.",
            "Restore cluster status before scheduling a model.",
        ));
    }
    Ok((draft, recipe))
}
fn schedule_draft(
    mut draft: PreviewDraft,
    request: &WarmupRequest,
    now: i64,
    minimum_lead: i64,
) -> Result<PreviewDraft, Failure> {
    let lead = request.due_at.checked_sub(now).ok_or_else(|| {
        error(
            StatusCode::UNPROCESSABLE_ENTITY,
            "WARMUP_TIME_INVALID",
            "Choose a time between one minute and seven days ahead.",
        )
    })?;
    if !(minimum_lead..=warmup::MAX_LEAD_SECONDS).contains(&lead) {
        return Err(error(
            StatusCode::UNPROCESSABLE_ENTITY,
            "WARMUP_TIME_INVALID",
            "Choose a time between one minute and seven days ahead.",
        ));
    }
    // Exclude transient present-time occupancy from future scheduling while retaining unsafe/provenance blockers and full due-time checks.
    draft.blockers.retain(|message| {
        !matches!(
            message.code.as_str(),
            "ENGINE_ACTIVE"
                | "EXTERNAL_ENGINE_ACTIVE"
                | "ENGINE_NOT_READY"
                | "MODEL_INSUFFICIENT_MEMORY"
                | "MEMORY_PRESSURE_ACTIVE"
        )
    });
    draft.action = "warmup";
    draft.action_key = crate::preview::action_key(
        "warmup",
        json!({"model_id":request.model_id,"profile_id":request.profile_id,"due_at":request.due_at,"expires_at":request.due_at+warmup::GRACE_SECONDS}),
    );
    draft.consequences = Default::default();
    // Remove immediate-replacement warnings from idle-only future delegation while preserving other safety warnings.
    draft.warnings.retain(|warning| {
        !matches!(
            warning.code.as_str(),
            "MODEL_ROUTE_INTERRUPTION" | "ACTIVE_REQUESTS_WILL_DRAIN"
        )
    });
    draft.warnings.push(PreviewMessage::warning(
        "WARMUP_IDLE_ONLY",
        "At the scheduled time the Spark will load this exact model and profile only if idle and memory admission still passes; otherwise it skips the warm-up. No workload will be stopped.",
    ));
    Ok(draft)
}
pub async fn preview_warmup(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    _idempotency: IdempotencyRequest,
    Json(request): Json<WarmupRequest>,
) -> Result<Json<Value>, Failure> {
    owner(&state, &principal)?;
    let (draft, _) = live_draft(&state, &request.model_id, &request.profile_id).await?;
    let draft = schedule_draft(
        draft,
        &request,
        state.clock.now().unix_timestamp(),
        warmup::MIN_LEAD_SECONDS,
    )?;
    Ok(Json(
        json!({"review":state.previews.issue(&draft).map_err(internal)?,"due_at":request.due_at,"expires_at":request.due_at+warmup::GRACE_SECONDS}),
    ))
}
pub async fn list_warmups(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
) -> Result<Json<Value>, Failure> {
    owner(&state, &principal)?;
    let database = state
        .database
        .as_ref()
        .ok_or_else(|| internal("database unavailable"))?;
    let conn = database.lock();
    warmup::reconcile(&conn, state.clock.now().unix_timestamp(), false).map_err(internal)?;
    Ok(Json(
        json!({"items":warmup::list(&conn).map_err(internal)?.into_iter().map(|stored| stored.schedule).collect::<Vec<_>>(),"max_pending":warmup::MAX_PENDING,"observed_at":state.clock.now().unix_timestamp()}),
    ))
}
pub async fn create_warmup(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    Extension(authenticated): Extension<AuthenticatedRequest>,
    idempotency: IdempotencyRequest,
    headers: HeaderMap,
    Json(request): Json<WarmupRequest>,
) -> Result<(StatusCode, Json<Value>), Failure> {
    owner(&state, &principal)?;
    let database = state
        .database
        .as_ref()
        .ok_or_else(|| internal("database unavailable"))?;
    if let Some(replay) = state
        .idempotency
        .lookup(&mut database.lock(), &idempotency)
        .map_err(|failure| failure.envelope())?
    {
        return Ok(json_response(&replay));
    }
    let (draft, _) = live_draft(&state, &request.model_id, &request.profile_id).await?;
    let now = state.clock.now().unix_timestamp();
    let draft = schedule_draft(draft, &request, now, 1)?;
    let _admission = state.idempotency.admission_guard();
    if let Some(replay) = state
        .idempotency
        .lookup(&mut database.lock(), &idempotency)
        .map_err(|failure| failure.envelope())?
    {
        return Ok(json_response(&replay));
    }
    presence(&state, &principal, &authenticated, &headers)?;
    if let Err(failure) = state.previews.validate(
        request.accepted_preview_digest.as_deref(),
        &draft,
        &format!("{}:{}", idempotency.device_id, idempotency.key),
    ) {
        crate::audit::append_refusal(
            database,
            state.clock.as_ref(),
            principal.device_id,
            &principal.role,
            ROUTE,
            "warmup.create",
            Some(&request.model_id),
            idempotency.request_id,
            failure.code(),
        )
        .map_err(crate::audit::unavailable_envelope)?;
        return Err(failure.envelope());
    }
    let pin =
        WarmupPin::from_draft(&draft).ok_or_else(|| internal("warm-up identity incomplete"))?;
    let outcome = state.idempotency.execute(&mut database.lock(), &idempotency, |tx| {
        warmup::reconcile(tx, now, false)?;
        let pending: i64 = tx.query_row("SELECT COUNT(*) FROM warmup_schedules WHERE state IN ('pending','dispatching','running')", [], |row| row.get(0))?;
        if pending >= warmup::MAX_PENDING { return Ok(StoredResponse { status:StatusCode::CONFLICT,body:error(StatusCode::CONFLICT,"WARMUP_LIMIT_REACHED","Disable a pending warm-up before scheduling another.").1.0,operation_id:None }); }
        if !warmup::owner_valid(tx, principal.device_id)? { return Ok(StoredResponse { status:StatusCode::FORBIDDEN,body:error(StatusCode::FORBIDDEN,"ROLE_FORBIDDEN","The scheduling device is no longer an owner.").1.0,operation_id:None }); }
        let schedule = warmup::insert(tx, &pin, principal.device_id, request.due_at, now)?;
        crate::audit::append(tx, state.clock.as_ref(), &crate::audit::AuditDraft {
            actor_device_id:Some(principal.device_id),actor_role:Some(&principal.role),source_route:ROUTE,action:"warmup.create",resource:Some(&pin.model_id),result:"accepted",operation_id:None,request_id:idempotency.request_id,details:&json!({"schedule_id":schedule.id,"profile_id":pin.profile_id,"due_at":request.due_at,"recipe_digest":pin.recipe_digest}),
        })?;
        Ok(StoredResponse {status:StatusCode::CREATED,body:json!(schedule),operation_id:None})
    }).map_err(|failure| failure.envelope())?;
    state.warmups.wake.notify_one();
    Ok(json_response(&outcome))
}
pub async fn disable_warmup(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    Extension(authenticated): Extension<AuthenticatedRequest>,
    Path(id): Path<Uuid>,
    idempotency: IdempotencyRequest,
    headers: HeaderMap,
) -> Result<(StatusCode, Json<Value>), Failure> {
    owner(&state, &principal)?;
    let database = state
        .database
        .as_ref()
        .ok_or_else(|| internal("database unavailable"))?;
    let _admission = state.idempotency.admission_guard();
    if let Some(replay) = state
        .idempotency
        .lookup(&mut database.lock(), &idempotency)
        .map_err(|failure| failure.envelope())?
    {
        return Ok(json_response(&replay));
    }
    presence(&state, &principal, &authenticated, &headers)?;
    let _dispatch = state.warmups.dispatch.lock();
    let outcome = state.idempotency.execute(&mut database.lock(), &idempotency, |tx| {
        // Revalidate owner authority inside the schedule transaction to catch concurrent demotion or revocation.
        if !warmup::owner_valid(tx, principal.device_id)? {
            return Ok(StoredResponse {status:StatusCode::FORBIDDEN,body:error(StatusCode::FORBIDDEN,"ROLE_FORBIDDEN","The device is no longer a Spark owner.").1.0,operation_id:None});
        }
        let Some(stored) = warmup::get(tx,id)? else { return Ok(StoredResponse {status:StatusCode::NOT_FOUND,body:error(StatusCode::NOT_FOUND,"WARMUP_NOT_FOUND","Warm-up not found.").1.0,operation_id:None}); };
        if matches!(stored.schedule.state.as_str(),"dispatching"|"running") { return Ok(StoredResponse {status:StatusCode::CONFLICT,body:error(StatusCode::CONFLICT,"WARMUP_ALREADY_DISPATCHED","This warm-up has already started; disabling cannot stop its model. Review the model operation instead.").1.0,operation_id:stored.schedule.operation_id}); }
        if stored.schedule.state != "pending" { return Ok(StoredResponse {status:StatusCode::OK,body:json!(stored.schedule),operation_id:None}); }
        warmup::terminal(tx,id,"disabled","WARMUP_DISABLED_BY_OWNER",state.clock.now().unix_timestamp())?;
        crate::audit::append(tx,state.clock.as_ref(),&crate::audit::AuditDraft {actor_device_id:Some(principal.device_id),actor_role:Some(&principal.role),source_route:ROUTE,action:"warmup.disable",resource:Some(&stored.schedule.model_id),result:"accepted",operation_id:None,request_id:idempotency.request_id,details:&json!({"schedule_id":id})})?;
        Ok(StoredResponse {status:StatusCode::OK,body:json!(warmup::get(tx,id)?.expect("retained schedule").schedule),operation_id:None})
    }).map_err(|failure| failure.envelope())?;
    state.warmups.wake.notify_one();
    Ok(json_response(&outcome))
}
