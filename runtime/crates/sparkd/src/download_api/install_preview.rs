use super::*;

pub(super) fn validate_engine_image_readiness(
    request_id: uuid::Uuid,
    requested_digest: &str,
    response: &PrivilegedResponse,
) -> Result<(), &'static str> {
    if response.request_id != request_id {
        return Err("privileged image preparation returned the wrong request identity");
    }
    if !response.accepted {
        return Err("privileged image preparation was rejected");
    }
    if response.code != "image_ready"
        || response.details.get("image_digest").and_then(Value::as_str) != Some(requested_digest)
    {
        return Err("privileged image preparation returned an invalid readiness claim");
    }
    if response
        .details
        .get("pulled")
        .and_then(Value::as_bool)
        .is_none()
    {
        return Err("privileged image preparation omitted its pull result");
    }
    Ok(())
}

#[derive(Debug, Default, serde::Deserialize)]
#[serde(deny_unknown_fields)]
pub struct InstallModelBody {
    #[serde(default)]
    pub recipe_revision: Option<String>,
    #[serde(default)]
    pub provider_credential_id: Option<String>,
    #[serde(default)]
    pub accepted_preview_digest: Option<String>,
}

#[derive(Debug, Default, serde::Deserialize)]
#[serde(deny_unknown_fields)]
pub struct InstallModelPreviewBody {
    #[serde(default)]
    pub recipe_revision: Option<String>,
    #[serde(default)]
    pub provider_credential_id: Option<String>,
}

pub(super) struct PreviewCredential {
    pub(super) id: Option<uuid::Uuid>,
    pub(super) path: Option<PathBuf>,
    pub(super) blocker: Option<PreviewMessage>,
}

pub(super) fn preview_credential(
    state: &AppState,
    recipe: &spark_models::ModelRecipe,
    raw_id: Option<&str>,
) -> Result<PreviewCredential, (StatusCode, Json<Value>)> {
    let Some(raw_id) = raw_id else {
        return Ok(PreviewCredential {
            id: None,
            path: None,
            blocker: recipe.source.gated.then(|| {
                PreviewMessage::blocker(
                    "MODEL_DOWNLOAD_AUTH_REQUIRED",
                    "This signed recipe requires a provider credential.",
                    "Choose a credential for the recipe provider and request a new preview.",
                )
            }),
        });
    };
    let credential_id = uuid::Uuid::parse_str(raw_id).map_err(|_| {
        (
            StatusCode::UNPROCESSABLE_ENTITY,
            Json(json!({ "error": { "code": "CREDENTIAL_INVALID", "message": "provider credential id must be a UUID" } })),
        )
    })?;
    let db = state
        .database
        .as_ref()
        .ok_or_else(|| internal_envelope("no database"))?;
    let store = CredentialStore::with_clock(&state.config.data_dir, state.clock.clone());
    let connection = db.lock();
    let path = store
        .resolve(&connection, credential_id)
        .map_err(|error| internal_envelope(&error))?;
    let provider = store
        .provider(&connection, credential_id)
        .map_err(|error| internal_envelope(&error))?;
    drop(connection);
    let blocker = if path.is_none() || provider.is_none() {
        Some(PreviewMessage::blocker(
            "CREDENTIAL_NOT_FOUND",
            "The selected provider credential is unavailable.",
            "Choose an available credential and request a new preview.",
        ))
    } else if provider.as_deref() != Some(recipe.source.provider.as_str()) {
        Some(PreviewMessage::blocker(
            "CREDENTIAL_PROVIDER_MISMATCH",
            "The selected credential does not match the recipe provider.",
            "Choose a credential for the recipe provider and request a new preview.",
        ))
    } else {
        None
    };
    Ok(PreviewCredential {
        id: Some(credential_id),
        path,
        blocker,
    })
}

pub(super) async fn install_preview_draft(
    state: &AppState,
    encoded_id: &str,
    recipe_revision: Option<&str>,
    provider_credential_id: Option<&str>,
) -> Result<(PreviewDraft, Option<uuid::Uuid>), (StatusCode, Json<Value>)> {
    let state = state.clone();
    let id = encoded_id.to_owned();
    let revision = recipe_revision.map(str::to_owned);
    let credential = provider_credential_id.map(str::to_owned);
    tokio::task::spawn_blocking(move || {
        install_preview_draft_blocking(&state, &id, revision.as_deref(), credential.as_deref())
    })
    .await
    .map_err(|_| internal_envelope("install evidence worker unavailable"))?
}

fn install_preview_draft_blocking(
    state: &AppState,
    encoded_id: &str,
    recipe_revision: Option<&str>,
    provider_credential_id: Option<&str>,
) -> Result<(PreviewDraft, Option<uuid::Uuid>), (StatusCode, Json<Value>)> {
    let inventory = state
        .models
        .as_ref()
        .ok_or_else(|| internal_envelope("inventory unavailable"))?
        .snapshot();
    let model_id = crate::models::decode_path_param(encoded_id);
    let recipe = inventory.recipe(&model_id).ok_or_else(|| {
        (
            StatusCode::NOT_FOUND,
            Json(
                json!({ "error": { "code": "MODEL_NOT_INSTALLED", "message": "model not found" } }),
            ),
        )
    })?;
    let db = state
        .database
        .as_ref()
        .ok_or_else(|| internal_envelope("no database"))?;
    let row = crate::store::model_row(&db.lock(), recipe.id())
        .map_err(|error| internal_envelope(&error.to_string()))?
        .ok_or_else(|| internal_envelope("model row missing"))?;
    let credential = preview_credential(state, recipe, provider_credential_id)?;
    let mut blockers = Vec::new();
    if recipe_revision.is_some_and(|revision| revision != recipe.metadata.revision) {
        blockers.push(PreviewMessage::blocker(
            "MODEL_RECIPE_REVISION_MISMATCH",
            "The requested recipe revision is no longer current.",
            "Review the current signed recipe and request a new preview.",
        ));
    }
    if row.install_state == "installed" {
        blockers.push(PreviewMessage::blocker(
            "MODEL_ALREADY_INSTALLED",
            "This model revision is already installed on the target.",
            "Use the installed model or remove it before installing again.",
        ));
    }
    if let Some(blocker) = credential.blocker.clone() {
        blockers.push(blocker);
    }

    let coordinator = state
        .download
        .coordinator
        .as_ref()
        .ok_or_else(|| internal_envelope("download coordinator unavailable"))?;
    let files = if credential.blocker.is_none() {
        match coordinator
            .resolver
            .resolve_with_credential(recipe, credential.path.as_deref())
        {
            Ok(files) => Some(files),
            Err(_) => {
                blockers.push(PreviewMessage::blocker(
                    "MODEL_MANIFEST_UNAVAILABLE",
                    "The immutable file manifest could not be read.",
                    "Check provider access and request a new preview.",
                ));
                None
            }
        }
    } else {
        None
    };
    let download_bytes = files.as_deref().map(crate::download::total_bytes);
    let locally_reusable_bytes = files
        .as_deref()
        .map(|files| {
            crate::download::preview_reusable_bytes(&state.storage.downloads, recipe, files)
        })
        .transpose()
        .map_err(|error| internal_envelope(&error.to_string()))?;
    let required_disk_bytes =
        download_bytes
            .zip(locally_reusable_bytes)
            .map(|(total, reusable)| {
                total
                    .saturating_sub(reusable)
                    .saturating_add(if recipe.uses_qwen38_preparation() {
                        30 * 1024 * 1024 * 1024
                    } else {
                        0
                    })
            });
    let system = state.telemetry.system();
    let expected_disk_free_after_bytes =
        required_disk_bytes.map(|required| system.disk_free_bytes.saturating_sub(required));
    if required_disk_bytes.is_some_and(|required| {
        system.disk_free_bytes < required.saturating_add(state.disk_reserve_bytes)
    }) {
        blockers.push(PreviewMessage::blocker(
            "MODEL_INSUFFICIENT_DISK",
            "The target cannot keep its minimum free-space reserve after this install.",
            "Free disk space or choose another target, then request a new preview.",
        ));
    }

    let (target, cluster_available, cluster) =
        target_and_cluster(state).map_err(|error| internal_envelope(&error))?;
    let (active_available, active, _) =
        active_engine(state).map_err(|error| internal_envelope(&error.to_string()))?;
    let binding = PreviewBinding {
        target,
        recipe: Some(
            PreviewRecipeIdentity::from_recipe(recipe, None)
                .map_err(|error| internal_envelope(&error.to_string()))?,
        ),
        evidence: PreviewEvidence {
            external_workload_id: None,
            external_workload_evidence_digest: None,
            external_workload_healthy: None,
            remote: None,
            install_state: Some(row.install_state),
            installed_bytes: row.total_bytes.and_then(|bytes| u64::try_from(bytes).ok()),
            removable_bytes: None,
            download_bytes,
            locally_reusable_bytes,
            required_disk_bytes,
            disk_free_bytes: Some(system.disk_free_bytes),
            expected_disk_free_after_bytes,
            required_memory_bytes: None,
            available_memory_bytes: Some(system.unified_memory_available_bytes),
            system_reserve_bytes: None,
            expected_memory_headroom_bytes: None,
            launch_memory: None,
            memory_pressure: Some(
                crate::guard::observed_pressure(state.guard.as_ref(), &system)
                    .api_name()
                    .to_owned(),
            ),
            memory_admission: None,
            profile_failure_code: None,
            active_inference_available: active_available,
            engine_transitioning: state
                .engine
                .manager
                .as_ref()
                .is_some_and(|manager| manager.is_transitioning()),
            active_engine: active,
            cluster_membership_available: cluster_available,
            cluster_membership_source: cluster_available.then(|| "runtime_cache".to_owned()),
            cluster,
        },
    };
    Ok((
        PreviewDraft {
            action: "install",
            action_key: action_key(
                "install",
                json!({
                    "model_id": recipe.id(),
                    "recipe_revision": recipe_revision,
                    "provider_credential_id": provider_credential_id,
                }),
            ),
            binding,
            consequences: PreviewConsequences::default(),
            blockers,
            warnings: Vec::new(),
        },
        credential.id,
    ))
}

/// Author the exact install evidence required by a subsequent apply.
pub async fn preview_install_model(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    idempotency: IdempotencyRequest,
    RoutePath(id): RoutePath<String>,
    Json(request): Json<InstallModelPreviewBody>,
) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    state
        .require(&principal, crate::capability::Capability::ModelInstall)
        .resource(format!(
            "model/{}/install/preview",
            crate::models::decode_path_param(&id)
        ))
        .check()?;
    let database = state
        .database
        .as_ref()
        .ok_or_else(|| internal_envelope("no database"))?;
    let draft_result = install_preview_draft(
        &state,
        &id,
        request.recipe_revision.as_deref(),
        request.provider_credential_id.as_deref(),
    )
    .await;
    let (draft, _) = match draft_result {
        Ok(draft) => draft,
        Err(failure) => {
            let resource = format!("model/{}", crate::models::decode_path_param(&id));
            let reason = crate::audit::response_code(&failure, "MODEL_PREVIEW_REFUSED");
            crate::audit::append_refusal(
                database,
                state.clock.as_ref(),
                principal.device_id,
                &principal.role,
                "/api/v1/models/{model_id}/install/preview",
                "model.install.preview",
                Some(&resource),
                idempotency.request_id,
                &reason,
            )
            .map_err(crate::audit::unavailable_envelope)?;
            return Err(failure);
        }
    };
    let preview = state
        .previews
        .issue(&draft)
        .map_err(|error| internal_envelope(&error.to_string()))?;
    let resource = format!("model/{}", crate::models::decode_path_param(&id));
    let details = json!({
        "preview_digest": preview.get("preview_digest"),
        "recipe_revision": request.recipe_revision,
    });
    crate::audit::append_committed(
        database,
        state.clock.as_ref(),
        &crate::audit::AuditDraft {
            actor_device_id: Some(principal.device_id),
            actor_role: Some(&principal.role),
            source_route: "/api/v1/models/{model_id}/install/preview",
            action: "model.install.preview",
            resource: Some(&resource),
            result: "accepted",
            operation_id: None,
            request_id: idempotency.request_id,
            details: &details,
        },
    )
    .map_err(crate::audit::unavailable_envelope)?;
    Ok(Json(preview))
}
