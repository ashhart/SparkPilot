use super::*;

pub async fn get_cluster_launch(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    Path(launch_id): Path<uuid::Uuid>,
) -> Result<Json<crate::cluster_coordination::ClusterLaunchStatus>, (StatusCode, Json<Value>)> {
    state
        .require(&principal, crate::capability::Capability::NodeRead)
        .resource("cluster-launch")
        .check()?;
    let coordinator = state.cluster_coordination.as_ref().ok_or_else(|| {
        cluster_envelope(
            "CLUSTER_MANAGEMENT_UNAVAILABLE",
            "this runtime has no cluster transaction backend",
            StatusCode::SERVICE_UNAVAILABLE,
        )
    })?;
    coordinator
        .launch_status(launch_id)
        .map(Json)
        .map_err(coordination_error)
}

pub async fn get_cluster_launches(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
) -> Result<Json<Vec<crate::cluster_coordination::ClusterLaunchStatus>>, (StatusCode, Json<Value>)>
{
    state
        .require(&principal, crate::capability::Capability::NodeRead)
        .resource("cluster-launches")
        .check()?;
    let coordinator = state.cluster_coordination.as_ref().ok_or_else(|| {
        cluster_envelope(
            "CLUSTER_MANAGEMENT_UNAVAILABLE",
            "this runtime has no cluster transaction backend",
            StatusCode::SERVICE_UNAVAILABLE,
        )
    })?;
    coordinator.launches().map(Json).map_err(coordination_error)
}

#[derive(serde::Deserialize)]
#[serde(deny_unknown_fields)]
pub struct StartClusterLaunchBody {
    pub cluster_id: uuid::Uuid,
    pub launch_id: uuid::Uuid,
    pub recipe_id: String,
    pub profile_id: String,
}

pub(super) fn distributed_execution_spec(
    state: &AppState,
    launch_id: uuid::Uuid,
    recipe_id: &str,
    profile_id: &str,
) -> Result<crate::cluster_coordination::DistributedExecutionSpec, (StatusCode, Json<Value>)> {
    let inventory = state.models.as_ref().ok_or_else(|| {
        cluster_envelope(
            "CATALOGUE_UNAVAILABLE",
            "the verified model catalogue is unavailable",
            StatusCode::SERVICE_UNAVAILABLE,
        )
    })?;
    let snapshot = inventory.snapshot();
    let recipe = snapshot.recipe(recipe_id).ok_or_else(|| {
        cluster_envelope(
            "MODEL_NOT_FOUND",
            "the selected signed model recipe does not exist",
            StatusCode::NOT_FOUND,
        )
    })?;
    recipe.validate().map_err(|_| {
        cluster_envelope(
            "MODEL_RECIPE_UNVERIFIED",
            "the selected model recipe failed verification",
            StatusCode::UNPROCESSABLE_ENTITY,
        )
    })?;
    let profile = recipe
        .profiles
        .iter()
        .find(|profile| profile.id == profile_id)
        .ok_or_else(|| {
            cluster_envelope(
                "MODEL_PROFILE_NOT_FOUND",
                "the selected profile is not part of the signed recipe",
                StatusCode::NOT_FOUND,
            )
        })?;
    let database = state
        .database
        .as_ref()
        .ok_or_else(|| internal_envelope("no database"))?;
    let installed: Option<(String, String, String)> = database
        .lock()
        .query_row(
            "SELECT install_state,recipe_revision,source_revision FROM models WHERE id=?1",
            [recipe.id()],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )
        .optional()
        .map_err(|error| internal_envelope(&error.to_string()))?;
    let exact_install =
        installed
            .as_ref()
            .is_some_and(|(state, recipe_revision, source_revision)| {
                state == "installed"
                    && recipe_revision == &recipe.metadata.revision
                    && source_revision == &recipe.source.revision
            });
    if !exact_install {
        return Err(cluster_envelope(
            "MODEL_NOT_INSTALLED",
            "install this exact signed model revision on every cluster member first",
            StatusCode::CONFLICT,
        ));
    }
    if crate::guard::profile_is_unsafe(&database.lock(), recipe.id(), &profile.id)
        .map_err(|error| internal_envelope(&error.to_string()))?
    {
        return Err(cluster_envelope(
            "MODEL_PROFILE_UNSAFE",
            "the selected profile is disabled by the memory guard",
            StatusCode::CONFLICT,
        ));
    }
    let snapshot_path = crate::model_paths::snapshot_path(
        &state.storage.models,
        recipe.id(),
        &recipe.source.revision,
    )
    .map_err(|error| internal_envelope(&error))?;
    let canonical = recipe
        .canonical_without_signature()
        .map_err(|error| internal_envelope(&error.to_string()))?;
    let spec = crate::cluster_coordination::DistributedExecutionSpec {
        recipe_id: recipe.id().to_owned(),
        profile_id: profile.id.clone(),
        recipe_digest: hex::encode(Sha256::digest(canonical)),
        source_revision: recipe.source.revision.clone(),
        image_digest: recipe.engine.image.clone(),
        served_name: recipe.engine.served_name.clone(),
        model_snapshot: snapshot_path.to_string_lossy().into_owned(),
        host_port: 18_100 + ((launch_id.as_u128() as u32) % 100) as u16,
        gpu_memory_utilisation_milli: (profile.gpu_memory_utilisation * 1_000.0).round() as u16,
        max_model_length: profile.max_model_length,
        max_sequences: profile.max_sequences,
        max_batched_tokens: profile.max_batched_tokens,
        tensor_parallel_size: 2,
    };
    spec.validate(launch_id).map_err(coordination_error)?;
    Ok(spec)
}

/// Check capability before presence or catalogue access, then derive executable launch inputs from the verified local catalogue.
pub async fn start_cluster_launch(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    Extension(authenticated_request): Extension<AuthenticatedRequest>,
    idempotency: IdempotencyRequest,
    headers: HeaderMap,
    axum::Json(body): axum::Json<StartClusterLaunchBody>,
) -> Result<(StatusCode, Json<Value>), (StatusCode, Json<Value>)> {
    if principal.role != "owner" {
        return Err(cluster_envelope(
            "ROLE_FORBIDDEN",
            "distributed cluster launch is owner-only",
            StatusCode::FORBIDDEN,
        ));
    }
    if !crate::cluster_coordination::CLUSTER_INFERENCE_QUALIFIED {
        crate::audit::append_refusal(
            state
                .database
                .as_ref()
                .ok_or_else(|| internal_envelope("no database"))?,
            state.clock.as_ref(),
            principal.device_id,
            &principal.role,
            START_LAUNCH_ROUTE,
            "cluster.launch.start",
            Some(CLUSTER_RESOURCE),
            idempotency.request_id,
            "CLUSTER_INFERENCE_UNAVAILABLE",
        )
        .map_err(crate::audit::unavailable_envelope)?;
        return Err(cluster_envelope(
            "CLUSTER_INFERENCE_UNAVAILABLE",
            "distributed inference remains unavailable until this runtime is physically qualified",
            StatusCode::SERVICE_UNAVAILABLE,
        ));
    }
    require_cluster_owner_presence(&state, &principal, &authenticated_request, &headers)?;
    let execution =
        distributed_execution_spec(&state, body.launch_id, &body.recipe_id, &body.profile_id)?;
    let coordinator = state.cluster_coordination.clone().ok_or_else(|| {
        cluster_envelope(
            "CLUSTER_MANAGEMENT_UNAVAILABLE",
            "this runtime has no cluster transaction backend",
            StatusCode::SERVICE_UNAVAILABLE,
        )
    })?;
    let _transaction = coordinator.transaction_guard().await;
    if let Some(replay) = lookup_transaction_replay(&state, &idempotency)? {
        return Ok(json_response(&replay));
    }
    let launch_id = body.launch_id;
    let cluster_id = body.cluster_id;
    let worker = coordinator.clone();
    tokio::task::spawn_blocking(move || {
        worker.start_local_launch(cluster_id, launch_id, &execution)
    })
    .await
    .map_err(|error| internal_envelope(&error.to_string()))?
    .map_err(coordination_error)?;
    let status = coordinator
        .launch_status(launch_id)
        .map_err(coordination_error)?;
    append_transaction_acceptance(
        &state,
        &principal,
        &idempotency,
        START_LAUNCH_ROUTE,
        "cluster.launch.start",
        launch_id,
        cluster_id,
    )?;
    let outcome = store_transaction_response(&state, &idempotency, &status)?;
    Ok(json_response(&outcome))
}

pub async fn stop_cluster_launch(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    Extension(authenticated_request): Extension<AuthenticatedRequest>,
    Path(launch_id): Path<uuid::Uuid>,
    idempotency: IdempotencyRequest,
    headers: HeaderMap,
) -> Result<(StatusCode, Json<Value>), (StatusCode, Json<Value>)> {
    if principal.role != "owner" {
        return Err(cluster_envelope(
            "ROLE_FORBIDDEN",
            "distributed cluster launch is owner-only",
            StatusCode::FORBIDDEN,
        ));
    }
    require_cluster_owner_presence(&state, &principal, &authenticated_request, &headers)?;
    let coordinator = state.cluster_coordination.clone().ok_or_else(|| {
        cluster_envelope(
            "CLUSTER_MANAGEMENT_UNAVAILABLE",
            "this runtime has no cluster transaction backend",
            StatusCode::SERVICE_UNAVAILABLE,
        )
    })?;
    let _transaction = coordinator.transaction_guard().await;
    if let Some(replay) = lookup_transaction_replay(&state, &idempotency)? {
        return Ok(json_response(&replay));
    }
    let worker = coordinator.clone();
    let status = tokio::task::spawn_blocking(move || worker.stop_local_launch(launch_id))
        .await
        .map_err(|error| internal_envelope(&error.to_string()))?
        .map_err(coordination_error)?;
    append_transaction_acceptance(
        &state,
        &principal,
        &idempotency,
        STOP_LAUNCH_ROUTE,
        "cluster.launch.stop",
        launch_id,
        status.cluster_id,
    )?;
    let outcome = store_transaction_response(&state, &idempotency, &status)?;
    Ok(json_response(&outcome))
}
