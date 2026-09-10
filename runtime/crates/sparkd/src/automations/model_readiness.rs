//! Load an installed, signed model for a scheduled task without replacing somebody else's engine.
use super::store::Automation;
use crate::{engine::EngineState, state::AppState};
use std::time::Duration;

fn active_matches(view: &crate::engine::EngineView, automation: &Automation) -> bool {
    view.model_id == automation.model_id
        && automation
            .profile_id
            .as_ref()
            .is_none_or(|profile| *profile == view.profile_id)
}

pub(super) async fn prepare(state: &AppState, automation: &Automation) -> Result<(), &'static str> {
    let database = state
        .database
        .as_ref()
        .ok_or("AUTOMATION_RUNNER_UNAVAILABLE")?;
    let manager = state
        .engine
        .manager
        .as_ref()
        .ok_or("AUTOMATION_RUNNER_UNAVAILABLE")?;
    {
        let conn = database.lock();
        let device = crate::store::load_device_by_id(&conn, &automation.owner_device_id)
            .map_err(|_| "AUTOMATION_OWNER_UNAVAILABLE")?;
        if !device.is_some_and(|device| matches!(device.role.as_str(), "owner" | "administrator")) {
            return Err("AUTOMATION_OWNER_UNAVAILABLE");
        }
    }
    if let Some(view) = manager.view() {
        if !active_matches(&view, automation) {
            return Err("AUTOMATION_MODEL_BUSY");
        }
        if view.state.accepts_requests() {
            return Ok(());
        }
        if matches!(
            view.state,
            EngineState::Failed | EngineState::Draining | EngineState::Stopping
        ) {
            return Err("AUTOMATION_MODEL_NOT_READY");
        }
    } else {
        let inventory = state
            .models
            .as_ref()
            .ok_or("MODEL_RECIPE_INVALID")?
            .snapshot();
        let recipe = inventory
            .recipe(&automation.model_id)
            .ok_or("MODEL_RECIPE_INVALID")?;
        state
            .catalogue_refresh
            .as_ref()
            .ok_or("MODEL_RECIPE_INVALID")?
            .verify_recipe(recipe)
            .map_err(|_| "MODEL_RECIPE_INVALID")?;
        let profile = match &automation.profile_id {
            Some(id) => recipe.profiles.iter().find(|profile| profile.id == *id),
            None => recipe
                .profiles
                .iter()
                .filter(|profile| profile.expected_peak_bytes > 0)
                .filter(|profile| {
                    manager
                        .admission_evidence(recipe, profile, false)
                        .is_ok_and(|evidence| {
                            matches!(
                                evidence.decision,
                                spark_telemetry::AdmissionDecision::Allow { .. }
                            )
                        })
                })
                .min_by_key(|profile| profile.expected_peak_bytes),
        }
        .ok_or("MODEL_PROFILE_UNSAFE")?;
        let operation = {
            let conn = database.lock();
            state
                .jobs
                .create(
                    &conn,
                    "model.load",
                    automation.owner_device_id,
                    Some(&automation.model_id),
                    &serde_json::json!({"model_id": automation.model_id, "profile_id": profile.id,
                    "automation_id": automation.id, "replace_active": false})
                    .to_string(),
                )
                .map_err(|_| "AUTOMATION_MODEL_LOAD_FAILED")?
        };
        if let Err(error) = manager.spawn_load(operation, recipe, &profile.id, false) {
            let _ = state.jobs.fail(&database.lock(), operation, error.code());
            return Err(error.code());
        }
    }
    // Loading has a separate bound; the answer's two-minute budget starts after readiness.
    tokio::time::timeout(Duration::from_secs(300), async {
        loop {
            if let Some(view) = manager.view() {
                if !active_matches(&view, automation) {
                    return Err("AUTOMATION_MODEL_BUSY");
                }
                if view.state.accepts_requests() {
                    return Ok(());
                }
                if matches!(
                    view.state,
                    EngineState::Failed | EngineState::Draining | EngineState::Stopping
                ) {
                    return Err("AUTOMATION_MODEL_LOAD_FAILED");
                }
            }
            tokio::time::sleep(Duration::from_millis(250)).await;
        }
    })
    .await
    .unwrap_or(Err("AUTOMATION_MODEL_LOAD_TIMEOUT"))
}
