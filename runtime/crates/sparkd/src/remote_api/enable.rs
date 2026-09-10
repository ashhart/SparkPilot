use super::*;

/// Publish each overlay stage on the operation and stop when the lease is lost or cancelled.
struct LeaseProgress<'a> {
    lease: &'a crate::jobs::OperationLease,
}

impl crate::remote::OverlayEnableProgress for LeaseProgress<'_> {
    fn stage(
        &self,
        stage: &str,
        _setup: Option<&crate::remote_overlay_setup::OverlaySetup>,
    ) -> bool {
        !self.lease.is_cancelled() && self.lease.set_stage(stage, None).is_ok()
    }
}

#[derive(serde::Deserialize)]
#[serde(deny_unknown_fields)]
pub struct EnableRemoteBody {
    pub mode: String,
    pub accepted_preview_digest: String,
}

pub(super) fn remote_draft_sync(
    state: &AppState,
    action: &'static str,
    mode: &str,
) -> Result<PreviewDraft, (StatusCode, Json<Value>)> {
    let remote = state
        .remote
        .as_ref()
        .ok_or_else(|| internal_envelope("remote access service unavailable"))?;
    let current = remote
        .status()
        .map_err(|error| internal_envelope(&error.to_string()))?;
    let mut blockers = Vec::new();
    let mut warnings = Vec::new();
    let mut hostname = current.hostname.clone();
    let mut provider = current.private_overlay_provider.clone();
    let mut overlay_setup_state = None;
    let requested_mode_available = match (action, mode) {
        ("remote.enable", "private_overlay") => match remote.private_overlay_route() {
            Ok(Some(route)) => {
                hostname = Some(route.hostname);
                provider = Some(route.provider);
                warnings.push(PreviewMessage::warning(
                    "EXISTING_TAILSCALE_CONFIGURATION",
                    "SparkPilot will use the Tailscale connection already configured on this Spark. It will not install Tailscale, sign in, or change the tailnet.",
                ));
                true
            }
            _ => {
                let setup = remote.overlay_setup().ok();
                overlay_setup_state = setup
                    .as_ref()
                    .map(|setup| setup.state.api_name().to_owned());
                match setup {
                    Some(setup) if setup.can_prepare() => {
                        provider = Some("tailscale".into());
                        warnings.push(PreviewMessage::warning(
                            "TAILSCALE_SETUP_REQUIRED",
                            "SparkPilot will set up Tailscale on this Spark: it installs or starts the Tailscale client and asks you to sign in to your Tailscale account once. If the sign-in does not finish, SparkPilot signs this Spark out again and stops the Tailscale service it started, and tells you if anything is left in place. Nothing else on the Spark changes.",
                        ));
                        true
                    }
                    setup => {
                        blockers.push(PreviewMessage::blocker(
                            "PRIVATE_OVERLAY_UNAVAILABLE",
                            "Tailscale cannot be set up on this Spark from the app.",
                            &overlay_recovery_action(setup.as_ref()),
                        ));
                        false
                    }
                }
            }
        },
        ("remote.disable", "disabled") => current.enabled,
        _ => {
            blockers.push(PreviewMessage::blocker(
                "REMOTE_MODE_INVALID",
                "This remote-access mode is not supported.",
                "Choose the installed private overlay, or keep this Spark local only.",
            ));
            false
        }
    };
    if action == "remote.enable" && current.enabled {
        blockers.push(PreviewMessage::blocker(
            "REMOTE_MODE_ALREADY_ENABLED",
            "Remote access is already enabled.",
            "Disable the current mode before selecting another route; credential rotation is not available yet.",
        ));
    }
    if action == "remote.disable" {
        warnings.push(PreviewMessage::warning(
            "LOCAL_ACCESS_RETAINED",
            "Local pairing and local routes stay available.",
        ));
        if current.mode == "private_overlay" {
            warnings.push(PreviewMessage::warning(
                "TAILSCALE_LEFT_CONFIGURED",
                "SparkPilot removes this remote route from the app. It does not stop or sign out the Tailscale client.",
            ));
        }
    }
    let (target, cluster_available, cluster) =
        target_and_cluster(state).map_err(|error| internal_envelope(&error))?;
    Ok(PreviewDraft {
        action,
        action_key: action_key(action, json!({ "mode": mode })),
        binding: PreviewBinding {
            target,
            recipe: None,
            evidence: PreviewEvidence {
                external_workload_id: None,
                external_workload_evidence_digest: None,
                external_workload_healthy: None,
                remote: Some(PreviewRemoteEvidence {
                    mode: current.mode,
                    health: current.health,
                    hostname,
                    requested_mode_available,
                    provider,
                    overlay_setup_state,
                }),
                install_state: None,
                installed_bytes: None,
                removable_bytes: None,
                download_bytes: None,
                locally_reusable_bytes: None,
                required_disk_bytes: None,
                disk_free_bytes: None,
                expected_disk_free_after_bytes: None,
                required_memory_bytes: None,
                available_memory_bytes: None,
                system_reserve_bytes: None,
                expected_memory_headroom_bytes: None,
                launch_memory: None,
                memory_pressure: None,
                memory_admission: None,
                profile_failure_code: None,
                active_inference_available: false,
                engine_transitioning: false,
                active_engine: None,
                cluster_membership_available: cluster_available,
                cluster_membership_source: cluster_available.then(|| "runtime_cache".into()),
                cluster,
            },
        },
        consequences: PreviewConsequences {
            route_withdrawal: action == "remote.disable",
            ..PreviewConsequences::default()
        },
        blockers,
        warnings,
    })
}

/// The owner's next step when the helper cannot carry Tailscale to a working route by itself.
fn overlay_recovery_action(setup: Option<&crate::remote_overlay_setup::OverlaySetup>) -> String {
    match setup {
        Some(setup) if setup.state == crate::remote_overlay_setup::OverlaySetupState::NotInstalled => {
            "Install Tailscale on the Spark yourself (its OS release is not one SparkPilot can install it on), sign in with `sudo tailscale up`, then try again.".into()
        }
        Some(setup) => format!(
            "Check Tailscale on the Spark with `tailscale status` ({}), then try again.",
            setup.detail.as_deref().unwrap_or("it reported an unexpected state")
        ),
        None => "Update the Spark runtime so its privileged helper can set Tailscale up, then try again.".into(),
    }
}

pub(super) async fn remote_draft(
    state: &AppState,
    action: &'static str,
    mode: &str,
) -> Result<PreviewDraft, (StatusCode, Json<Value>)> {
    let worker_state = state.clone();
    let mode = mode.to_owned();
    tokio::task::spawn_blocking(move || remote_draft_sync(&worker_state, action, &mode))
        .await
        .map_err(|_| internal_envelope("remote access review probe stopped"))?
}

pub async fn preview_enable_remote_access(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    idempotency: IdempotencyRequest,
    axum::Json(body): axum::Json<RemotePreviewBody>,
) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    if principal.role != "owner" {
        append_refusal(
            &state,
            &principal,
            &idempotency,
            "/api/v1/remote/enable/preview",
            "remote.enable.preview",
            "ROLE_FORBIDDEN",
        )?;
        return Err(error_envelope(
            StatusCode::FORBIDDEN,
            "ROLE_FORBIDDEN",
            "remote access is owner-only",
        ));
    }
    let draft = remote_draft(&state, "remote.enable", &body.mode).await?;
    let preview = state
        .previews
        .issue(&draft)
        .map_err(|_| internal_envelope("remote access review could not be issued"))?;
    Ok(Json(preview))
}

/// `POST /api/v1/remote/enable` — 202 with the durable operation.
pub async fn enable_remote_access(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    Extension(authenticated_request): Extension<AuthenticatedRequest>,
    idempotency: IdempotencyRequest,
    headers: HeaderMap,
    axum::Json(body): axum::Json<EnableRemoteBody>,
) -> Result<(StatusCode, Json<Value>), (StatusCode, Json<Value>)> {
    let Some(db) = &state.database else {
        return Err(internal_envelope("no database"));
    };
    if principal.role != "owner" {
        append_refusal(
            &state,
            &principal,
            &idempotency,
            ENABLE_ROUTE,
            "remote.enable",
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

    // Reject invalid enable input synchronously with its specific error before queuing an operation.
    if body.mode != "private_overlay" {
        append_refusal(
            &state,
            &principal,
            &idempotency,
            ENABLE_ROUTE,
            "remote.enable",
            "REMOTE_MODE_INVALID",
        )?;
        return Err(error_envelope(
            StatusCode::UNPROCESSABLE_ENTITY,
            "REMOTE_MODE_INVALID",
            "mode must be private_overlay",
        ));
    }

    let draft = remote_draft(&state, "remote.enable", &body.mode).await?;
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
            ENABLE_ROUTE,
            "remote.enable",
            error.code(),
        )?;
        return Err(error_envelope(
            StatusCode::FORBIDDEN,
            error.code(),
            "fresh user presence is required to enable remote access",
        ));
    }

    let outcome = {
        let _admission = state.idempotency.admission_guard();
        let mut conn = db.lock();
        let details = json!({ "mode": body.mode });
        state
            .idempotency
            .create_operation_audited(
                &mut conn,
                &idempotency,
                &state.jobs,
                "remote.enable",
                None,
                &json!({ "mode": body.mode }).to_string(),
                &principal.role,
                ENABLE_ROUTE,
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
    let mode = body.mode.clone();
    state
        .jobs
        .spawn_leased(worker_db, operation_id, move |lease| {
            // Let the remote service acquire its own nonreentrant database lock to avoid self-deadlock.
            let outcome = {
                let progress = LeaseProgress { lease: &lease };
                remote.enable_with_progress(&mode, &progress)
            };
            match outcome {
                Ok(row) => {
                    if let Err(error) = lease.succeed(
                        &json!({ "mode": row.mode, "health": row.health, "hostname": row.hostname }),
                    ) {
                        tracing::error!(
                            operation_id = %operation_id,
                            error = %error,
                            "could not persist remote enable success"
                        );
                    }
                }
                Err(failure) => {
                    tracing::warn!(operation_id = %operation_id, error = %failure, "remote enable failed");
                    if let Err(error) = lease.fail(crate::remote::enable_failure_code(&failure)) {
                        tracing::error!(
                            operation_id = %operation_id,
                            error = %error,
                            "could not persist remote enable failure"
                        );
                    }
                }
            }
        })
        .map_err(|error| crate::api_error::spawn_envelope(&error))?;

    Ok(json_response(&outcome))
}
