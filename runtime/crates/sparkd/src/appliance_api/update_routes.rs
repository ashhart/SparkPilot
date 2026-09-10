use super::*;

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct InstallSoftwareUpdatesRequest {
    system_packages: bool,
    firmware: bool,
    runtime_release_id: Option<String>,
    runtime_release_bundle: Option<RuntimeReleaseBundleRequest>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RuntimeReleaseBundleRequest {
    release_id: String,
    manifest_base64: String,
    package_base64: String,
    signature_base64: String,
}

impl RuntimeReleaseBundleRequest {
    fn decode(self) -> Result<crate::runtime_release::RuntimeReleaseBundle, String> {
        let decode = |name: &str, value: String| {
            base64::engine::general_purpose::STANDARD
                .decode(value)
                .map_err(|_| format!("{name} is not valid base64"))
        };
        let bundle = crate::runtime_release::RuntimeReleaseBundle {
            release_id: self.release_id,
            manifest: decode("manifest_base64", self.manifest_base64)?,
            package: decode("package_base64", self.package_base64)?,
            signature: decode("signature_base64", self.signature_base64)?,
        };
        bundle.validate().map_err(|error| error.to_string())?;
        Ok(bundle)
    }
}

pub async fn refresh_software_updates(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    Extension(authenticated): Extension<AuthenticatedRequest>,
    idempotency: IdempotencyRequest,
    headers: HeaderMap,
) -> Result<(StatusCode, Json<Value>), (StatusCode, Json<Value>)> {
    let privileged = state.privileged.clone().ok_or_else(|| {
        error_envelope(
            StatusCode::SERVICE_UNAVAILABLE,
            "UPDATE_SERVICE_UNAVAILABLE",
            "software update detection is unavailable",
        )
    })?;
    enqueue_operation(
        state,
        principal,
        authenticated,
        idempotency,
        headers,
        "/api/v1/system/updates/check",
        "system.software_update_check",
        json!({}),
        None,
        move |operation_id, lease| {
            let result = privileged.call(PrivilegedOperation::RefreshSystemUpdates {
                request_id: operation_id,
            });
            finish_privileged(
                lease,
                result,
                json!({ "metadata_refreshed": true }),
                "UPDATE_CHECK_FAILED",
            );
        },
    )
    .await
}

pub async fn install_software_updates(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    Extension(authenticated): Extension<AuthenticatedRequest>,
    idempotency: IdempotencyRequest,
    headers: HeaderMap,
    Json(request): Json<InstallSoftwareUpdatesRequest>,
) -> Result<(StatusCode, Json<Value>), (StatusCode, Json<Value>)> {
    if !request.system_packages
        && !request.firmware
        && request.runtime_release_id.is_none()
        && request.runtime_release_bundle.is_none()
    {
        return Err(error_envelope(
            StatusCode::BAD_REQUEST,
            "NO_UPDATES_SELECTED",
            "select at least one update",
        ));
    }
    if state
        .engine
        .manager
        .as_ref()
        .and_then(|engine| engine.view())
        .is_some()
    {
        return Err(error_envelope(
            StatusCode::CONFLICT,
            "INFERENCE_MUST_BE_UNLOADED",
            "unload the active model before updating this Spark",
        ));
    }
    // §45.2 step 4: durable work that writes the runtime's own files must finish before the daemon stops.
    const FILESYSTEM_MUTATIONS: [&str; 5] = [
        "model.install",
        "model.remove",
        "model.load",
        "model.unload",
        "catalogue.refresh",
    ];
    if let Some(database) = state.database.as_ref() {
        let live = crate::store::live_operation_of_kind(&database.lock(), &FILESYSTEM_MUTATIONS)
            .map_err(|error| internal_envelope(&error.to_string()))?;
        if let Some((operation_id, kind)) = live {
            return Err(detailed_error_envelope(
                StatusCode::CONFLICT,
                "UPDATE_BLOCKED_BY_OPERATION",
                "wait for the running operation to finish before updating this Spark",
                json!({ "operation_id": operation_id, "operation_kind": kind }),
            ));
        }
    }
    const UPDATE_RESERVE_BYTES: u64 = 8 * 1024 * 1024 * 1024;
    if state.telemetry.hardware().storage.free_bytes < UPDATE_RESERVE_BYTES {
        return Err(error_envelope(
            StatusCode::CONFLICT,
            "UPDATE_STORAGE_RESERVE_LOW",
            "free at least 8 GiB before installing updates",
        ));
    }
    let privileged = state.privileged.clone().ok_or_else(|| {
        error_envelope(
            StatusCode::SERVICE_UNAVAILABLE,
            "UPDATE_SERVICE_UNAVAILABLE",
            "software updates are unavailable",
        )
    })?;
    let system_packages = request.system_packages;
    let firmware = request.firmware;
    let runtime_release_bundle = request
        .runtime_release_bundle
        .map(RuntimeReleaseBundleRequest::decode)
        .transpose()
        .map_err(|message| {
            error_envelope(
                StatusCode::BAD_REQUEST,
                "INVALID_RUNTIME_RELEASE_BUNDLE",
                &message,
            )
        })?;
    if let (Some(requested), Some(bundle)) = (
        request.runtime_release_id.as_deref(),
        runtime_release_bundle.as_ref(),
    ) && requested != bundle.release_id
    {
        return Err(error_envelope(
            StatusCode::BAD_REQUEST,
            "RUNTIME_RELEASE_ID_MISMATCH",
            "the staged bundle and requested runtime release differ",
        ));
    }
    let runtime_release_id = request.runtime_release_id.or_else(|| {
        runtime_release_bundle
            .as_ref()
            .map(|bundle| bundle.release_id.clone())
    });
    let runtime_package_bytes = runtime_release_bundle
        .as_ref()
        .map(|bundle| bundle.package.len());
    let runtime_update_staging_root = state.runtime_update_staging_root.clone();
    let audit_release = runtime_release_id.clone();
    enqueue_operation(
        state,
        principal,
        authenticated,
        idempotency,
        headers,
        "/api/v1/system/updates",
        "system.software_updates",
        json!({
            "system_packages": system_packages,
            "firmware": firmware,
            "runtime_release_id": audit_release,
            "runtime_bundle_supplied": runtime_release_bundle.is_some(),
            "runtime_package_bytes": runtime_package_bytes,
        }),
        None,
        move |operation_id, lease| {
            let mut failure = None;
            if let Some(bundle) = runtime_release_bundle.as_ref()
                && let Err(error) = crate::runtime_release::stage_runtime_release(
                    runtime_update_staging_root.as_ref(),
                    bundle,
                )
            {
                tracing::error!(%error, "runtime release staging failed");
                failure = Some("RUNTIME_RELEASE_STAGING_FAILED".into());
            }
            if (system_packages || firmware) && failure.is_none() {
                match privileged.call(PrivilegedOperation::InstallSystemUpdates {
                    request_id: operation_id,
                    system_packages,
                    firmware,
                }) {
                    // Follow the helper's detached job through completion.
                    Ok(response)
                        if response.accepted && response.code == "system_update.scheduled" =>
                    {
                        let job_id = response
                            .details
                            .get("job_id")
                            .and_then(Value::as_str)
                            .map(str::to_owned)
                            .unwrap_or_else(|| operation_id.to_string());
                        if let Err(code) = wait_for_system_update_job(&privileged, &job_id, &lease)
                        {
                            failure = Some(code);
                        }
                    }
                    Ok(response) if response.accepted => {}
                    Ok(response) => failure = Some(response.code),
                    Err(error) => {
                        tracing::error!(%error, "system software update failed");
                        failure = Some("SYSTEM_UPDATE_FAILED".into());
                    }
                }
            }
            if failure.is_none()
                && let Some(release_id) = runtime_release_id.as_ref()
            {
                if lease
                    .set_stage("runtime_update_scheduling", Some(0.8))
                    .is_err()
                {
                    return;
                }
                match privileged.call(PrivilegedOperation::InstallRuntimeUpdate {
                    request_id: operation_id,
                    release_id: release_id.clone(),
                }) {
                    Ok(response) if response.accepted => {
                        complete_runtime_update(
                            &privileged,
                            release_id,
                            system_packages,
                            firmware,
                            lease,
                        );
                        return;
                    }
                    Ok(response) => {
                        tracing::error!(
                            code = %response.code,
                            message = %response.message,
                            "privileged helper refused to schedule the runtime update"
                        );
                        failure = Some(runtime_update_failure_code(&response));
                    }
                    Err(error) => {
                        tracing::error!(%error, "runtime software update failed");
                        failure = Some("RUNTIME_UPDATE_FAILED".into());
                    }
                }
            }
            if let Some(code) = failure {
                lease.settle_failed(&code);
            } else {
                lease.settle_succeeded(&json!({
                    "system_packages": system_packages,
                    "firmware": firmware,
                    "runtime_release_id": runtime_release_id,
                }));
            }
        },
    )
    .await
}

/// Preserve specific UPDATE_* scheduling reasons from helper errors so callers do not misclassify refusal as unsupported runtime updates.
pub(crate) fn runtime_update_failure_code(
    response: &spark_privd::protocol::PrivilegedResponse,
) -> String {
    response
        .message
        .split_whitespace()
        .find(|part| part.starts_with("UPDATE_") && part.len() <= 96)
        .map(|part| {
            part.trim_end_matches(|character: char| {
                !character.is_ascii_alphanumeric() && character != '_'
            })
            .to_owned()
        })
        .unwrap_or_else(|| response.code.clone())
}

pub(crate) fn complete_runtime_update(
    privileged: &crate::privd::PrivilegedClient,
    release_id: &str,
    system_packages: bool,
    firmware: bool,
    lease: crate::jobs::OperationLease,
) {
    if lease
        .set_stage("runtime_update_restarting", Some(0.9))
        .is_err()
    {
        return;
    }
    for _ in 0..600 {
        // The helper installs and restarts the runtime for minutes; keep the lease alive so housekeeping does not fail a live update.
        let _ = lease.renew_now();
        let status = privileged.call_bounded(
            PrivilegedOperation::RuntimeUpdateStatus {
                request_id: Uuid::new_v4(),
                release_id: release_id.to_owned(),
            },
            std::time::Duration::from_secs(5),
        );
        match status {
            Ok(response)
                if matches!(
                    response.code.as_str(),
                    "update.committed" | "update.already_committed"
                ) =>
            {
                lease.settle_succeeded(&json!({
                    "system_packages": system_packages,
                    "firmware": firmware,
                    "runtime_release_id": release_id,
                    "runtime_outcome": response.code,
                }));
                return;
            }
            Ok(response) if response.code == "update.rolled_back" => {
                lease.settle_failed("RUNTIME_UPDATE_ROLLED_BACK");
                return;
            }
            Ok(response) if response.code == "update.data_restored_package_manual" => {
                lease.settle_failed("RUNTIME_UPDATE_MANUAL_RECOVERY_REQUIRED");
                return;
            }
            Ok(response) if response.code.starts_with("UPDATE_") => {
                lease.settle_failed(&response.code);
                return;
            }
            Ok(_) | Err(_) => {
                std::thread::sleep(std::time::Duration::from_secs(1));
            }
        }
    }
    lease.settle_failed("RUNTIME_UPDATE_STATUS_TIMEOUT");
}

/// Renew the operation lease while polling detached OS updates through completion.
pub(super) fn wait_for_system_update_job(
    privileged: &crate::privd::PrivilegedClient,
    job_id: &str,
    lease: &crate::jobs::OperationLease,
) -> Result<Value, String> {
    const POLL_INTERVAL: std::time::Duration = std::time::Duration::from_secs(3);
    // Two hours: a full DGX OS dist-upgrade over a slow link.
    const MAXIMUM_POLLS: usize = 2400;
    let _ = lease.set_stage("system_update_installing", Some(0.3));
    for _ in 0..MAXIMUM_POLLS {
        let _ = lease.renew_now();
        let status = privileged.call_bounded(
            PrivilegedOperation::SystemUpdateStatus {
                request_id: Uuid::new_v4(),
                job_id: job_id.to_owned(),
            },
            std::time::Duration::from_secs(10),
        );
        match status {
            Ok(response) if response.code == "system_update.succeeded" => {
                return Ok(response.details);
            }
            Ok(response) if response.code == "system_update.failed" => {
                tracing::error!(details = %response.details, "the OS update worker failed");
                return Err("SYSTEM_UPDATE_FAILED".into());
            }
            Ok(response) if response.code.starts_with("UPDATE_") => return Err(response.code),
            Ok(_) | Err(_) => std::thread::sleep(POLL_INTERVAL),
        }
    }
    Err("SYSTEM_UPDATE_STATUS_TIMEOUT".into())
}
