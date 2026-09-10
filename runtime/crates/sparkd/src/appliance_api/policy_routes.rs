use super::*;

pub async fn update_memory_guard(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    Extension(authenticated): Extension<AuthenticatedRequest>,
    idempotency: IdempotencyRequest,
    headers: HeaderMap,
    Json(request): Json<MemoryGuardConfig>,
) -> Result<(StatusCode, Json<Value>), (StatusCode, Json<Value>)> {
    let config = request.validate().map_err(|message| {
        error_envelope(
            StatusCode::BAD_REQUEST,
            "INVALID_MEMORY_THRESHOLDS",
            message,
        )
    })?;
    let database = state
        .database
        .clone()
        .ok_or_else(|| internal_envelope("settings database is unavailable"))?;
    let guard = state.guard.clone();
    let timestamp = observed_at(&state);
    let device_id = principal.device_id;
    enqueue_operation(
        state,
        principal,
        authenticated,
        idempotency,
        headers,
        "/api/v1/settings/memory-guard",
        "settings.memory_guard",
        json!(config),
        None,
        move |_operation_id, lease| {
            let stored = {
                let connection = database.lock();
                store_setting(&connection, MEMORY_KEY, &config, &timestamp, device_id)
            };
            match stored {
                Ok(()) => {
                    if let Some(guard) = guard {
                        guard.update_policy(config.apply_to(guard.policy()));
                    }
                    lease.settle_succeeded(&json!(config));
                }
                Err(error) => {
                    tracing::error!(%error, "memory guard setting persistence failed");
                    lease.settle_failed("SETTINGS_PERSISTENCE_FAILED");
                }
            }
        },
    )
    .await
}

pub async fn update_model_idle_policy(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    Extension(authenticated): Extension<AuthenticatedRequest>,
    idempotency: IdempotencyRequest,
    headers: HeaderMap,
    Json(request): Json<ModelIdlePolicyConfig>,
) -> Result<(StatusCode, Json<Value>), (StatusCode, Json<Value>)> {
    let recipe = state
        .models
        .as_ref()
        .and_then(|inventory| inventory.snapshot().recipe(&request.model_id).cloned())
        .ok_or_else(|| {
            error_envelope(
                StatusCode::NOT_FOUND,
                "MODEL_NOT_FOUND",
                "the model is not in this Spark's verified catalogue",
            )
        })?;
    let profile = recipe
        .profiles
        .iter()
        .find(|profile| profile.id == request.profile_id)
        .ok_or_else(|| {
            error_envelope(
                StatusCode::BAD_REQUEST,
                "PROFILE_NOT_FOUND",
                "the selected profile does not belong to this model",
            )
        })?;
    let supported = crate::models::supported_idle_policies(&recipe, &profile.idle_policy);
    if !supported
        .iter()
        .any(|policy| policy == &request.idle_policy)
    {
        return Err(error_envelope(
            StatusCode::BAD_REQUEST,
            "IDLE_POLICY_UNSUPPORTED",
            "the selected engine profile does not support that idle policy",
        ));
    }
    if request.idle_timeout_seconds.is_some_and(|seconds| {
        !(60..=604800).contains(&seconds)
            || !recipe.engine.recipe.starts_with("vllm-")
            || !matches!(
                request.idle_policy.as_str(),
                "unload_after_15m" | "unload_after_30m" | "unload_after_60m"
            )
    }) {
        return Err(error_envelope(
            StatusCode::BAD_REQUEST,
            "IDLE_TIMEOUT_INVALID",
            "custom idle timeouts require a timed policy and must be between 60 and 604800 seconds",
        ));
    }
    let database = state
        .database
        .clone()
        .ok_or_else(|| internal_envelope("settings database is unavailable"))?;
    let timestamp = observed_at(&state);
    let device_id = principal.device_id;
    let engine = state.engine.manager.clone();
    let config = request;
    enqueue_operation(
        state,
        principal,
        authenticated,
        idempotency,
        headers,
        "/api/v1/settings/model-idle",
        "settings.model_idle_policy",
        json!(config),
        None,
        move |_operation_id, lease| {
            let result = (|| -> Result<(), rusqlite::Error> {
                let mut conn = database.lock();
                let tx = conn.transaction()?;
                tx.execute(
                "INSERT INTO model_idle_policies(model_id, profile_id, idle_policy, updated_at, updated_by_device_id)
                 VALUES (?1, ?2, ?3, ?4, ?5)
                 ON CONFLICT(model_id, profile_id) DO UPDATE SET
                   idle_policy = excluded.idle_policy,
                   updated_at = excluded.updated_at,
                   updated_by_device_id = excluded.updated_by_device_id",
                rusqlite::params![
                    config.model_id,
                    config.profile_id,
                    config.idle_policy,
                    timestamp,
                    device_id.to_string(),
                ],
            )?;
                tx.execute("DELETE FROM model_idle_timeouts WHERE model_id = ?1 AND profile_id = ?2",
                    rusqlite::params![config.model_id, config.profile_id])?;
                if let Some(seconds) = config.idle_timeout_seconds {
                    tx.execute("INSERT INTO model_idle_timeouts(model_id, profile_id, timeout_seconds) VALUES (?1, ?2, ?3)",
                        rusqlite::params![config.model_id, config.profile_id, seconds])?;
                }
                tx.commit()
            })();
            match result {
                Ok(_) => {
                    if let Some(engine) = engine {
                        engine.refresh_idle_policy(&config.model_id, &config.profile_id);
                    }
                    lease.settle_succeeded(&json!(config));
                }
                Err(error) => {
                    tracing::error!(%error, "idle policy persistence failed");
                    lease.settle_failed("SETTINGS_PERSISTENCE_FAILED");
                }
            }
        },
    )
    .await
}

pub async fn update_telemetry_consent(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    Extension(authenticated): Extension<AuthenticatedRequest>,
    idempotency: IdempotencyRequest,
    headers: HeaderMap,
    Json(config): Json<TelemetryConsentConfig>,
) -> Result<(StatusCode, Json<Value>), (StatusCode, Json<Value>)> {
    let database = state
        .database
        .clone()
        .ok_or_else(|| internal_envelope("settings database is unavailable"))?;
    let timestamp = observed_at(&state);
    let device_id = principal.device_id;
    let live_consent = state.telemetry_consent.clone();
    let technical_diagnostics = state.technical_diagnostics.clone();
    enqueue_operation(
        state,
        principal,
        authenticated,
        idempotency,
        headers,
        "/api/v1/settings/telemetry",
        "settings.telemetry_consent",
        json!(config),
        None,
        move |_operation_id, lease| {
            let result = {
                let connection = database.lock();
                let result =
                    store_setting(&connection, TELEMETRY_KEY, &config, &timestamp, device_id);
                if result.is_ok() {
                    // Publish under the database lock so concurrent consent operations and writers share one order.
                    *live_consent.write() = config;
                    technical_diagnostics
                        .store(config.technical, std::sync::atomic::Ordering::Relaxed);
                }
                result
            };
            match result {
                Ok(()) => {
                    lease.settle_succeeded(&json!(config));
                }
                Err(error) => {
                    tracing::error!(%error, "telemetry consent persistence failed");
                    lease.settle_failed("SETTINGS_PERSISTENCE_FAILED");
                }
            }
        },
    )
    .await
}
