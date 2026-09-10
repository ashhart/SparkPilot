//! Combine verified catalogue recipes with local install state and current fit evidence.

use std::path::Path;

use std::sync::Arc;

use axum::extract::{Extension, Path as RoutePath, State};

use axum::http::StatusCode;

use axum::response::Json;

use serde::Deserialize;

use serde_json::{Value, json};

use spark_models::ModelRecipe;

use spark_models::catalogue::{SignedCatalogue, load_catalogue};

use spark_models::fit::{FitState, compute_fit};

use spark_models::verify::CatalogueRoot;

use crate::auth::Principal;

use crate::idempotency::{IdempotencyRequest, StoredResponse, json_response};

use crate::preview::{
    PreviewBinding, PreviewConsequences, PreviewDraft, PreviewEvidence, PreviewMessage,
    PreviewRecipeIdentity, action_key, active_engine, target_and_cluster,
};

use crate::state::AppState;

use crate::store;

fn internal_error() -> (StatusCode, Json<Value>) {
    (
        StatusCode::INTERNAL_SERVER_ERROR,
        Json(json!({ "error": { "code": "INTERNAL_ERROR", "message": "INTERNAL_ERROR" } })),
    )
}

/// List model catalogue and installed inventory for the caller's role.
pub async fn list_models_impl(state: &AppState) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    let inventory = state.models.as_ref().ok_or(internal_error())?.snapshot();
    let Some(conn) = &state.database else {
        return Err(internal_error());
    };

    // Resolve transition evidence before acquiring the database lock because those helpers acquire it themselves.
    let (_target, cluster_available, _cluster) =
        target_and_cluster(state).map_err(|error| internal_envelope(&error))?;
    let (residency_known, _active, _) =
        active_engine(state).map_err(|error| internal_envelope(&error.to_string()))?;
    let available = state.telemetry.system().unified_memory_available_bytes;
    let reclaimable = state
        .engine
        .manager
        .as_ref()
        .map(|engine| {
            engine
                .replacement_available_memory_bytes(available)
                .saturating_sub(available)
        })
        .unwrap_or(0);

    let guard = conn.lock();

    let mut items = Vec::new();
    for recipe in &inventory.recipes {
        let row = match store::model_row(&guard, recipe.id())
            .map_err(|e| internal_envelope(&e.to_string()))?
        {
            Some(row) => row,
            None => {
                store::upsert_catalogue_model(&guard, recipe)
                    .map_err(|e| internal_envelope(&e.to_string()))?;
                store::model_row(&guard, recipe.id())
                    .map_err(|e| internal_envelope(&e.to_string()))?
                    .ok_or_else(|| internal_envelope("model row missing after upsert"))?
            }
        };
        items.push(model_view(
            &guard,
            recipe,
            &row,
            available,
            reclaimable,
            cluster_available,
            residency_known,
            state
                .engine
                .manager
                .as_ref()
                .map(|engine| engine.system_reserve_bytes(recipe))
                .unwrap_or(recipe.memory.minimum_system_reserve_bytes),
        ));
    }
    Ok(Json(json!({ "items": items, "next_cursor": null })))
}

pub(crate) fn internal_envelope(message: &str) -> (StatusCode, Json<Value>) {
    (
        StatusCode::INTERNAL_SERVER_ERROR,
        Json(json!({ "error": { "code": "INTERNAL_ERROR", "message": message } })),
    )
}

pub async fn list_models(
    State(state): State<AppState>,
    axum::extract::Extension(principal): axum::extract::Extension<crate::auth::Principal>,
) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    // Shared access never exposes the owner's catalogue; a guest sees only the models the owner shared, through /v1/models.
    crate::guest::refuse_guest(&state, &principal, "models")?;
    list_models_impl(&state).await
}

/// Decode encoded model IDs in route parameters without modifying the signed request target.
pub(crate) fn decode_path_param(input: &str) -> String {
    let bytes = input.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%'
            && i + 2 < bytes.len()
            && let (Some(hi), Some(lo)) = (hex_value(bytes[i + 1]), hex_value(bytes[i + 2]))
        {
            out.push(hi * 16 + lo);
            i += 3;
            continue;
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn hex_value(b: u8) -> Option<u8> {
    match b {
        b'0'..=b'9' => Some(b - b'0'),
        b'a'..=b'f' => Some(b - b'a' + 10),
        b'A'..=b'F' => Some(b - b'A' + 10),
        _ => None,
    }
}

fn not_found() -> (StatusCode, Json<Value>) {
    (
        StatusCode::NOT_FOUND,
        Json(json!({ "error": { "code": "MODEL_NOT_INSTALLED", "message": "model not found" } })),
    )
}

/// Return details for one model.
pub async fn get_model(
    State(state): State<AppState>,
    RoutePath(id): RoutePath<String>,
) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    let id = decode_path_param(&id);
    let inventory = state.models.as_ref().ok_or(internal_error())?.snapshot();
    let recipe = inventory.recipe(&id).ok_or_else(not_found)?;
    let Some(conn) = &state.database else {
        return Err(internal_error());
    };

    // Resolve shared list/detail transition evidence before acquiring the database lock.
    let (_target, cluster_available, _cluster) =
        target_and_cluster(&state).map_err(|error| internal_envelope(&error))?;
    let (residency_known, _active, _) =
        active_engine(&state).map_err(|error| internal_envelope(&error.to_string()))?;
    let available = state.telemetry.system().unified_memory_available_bytes;
    let reclaimable = state
        .engine
        .manager
        .as_ref()
        .map(|engine| {
            engine
                .replacement_available_memory_bytes(available)
                .saturating_sub(available)
        })
        .unwrap_or(0);

    let guard = conn.lock();
    let row = store::model_row(&guard, &id)
        .map_err(|e| internal_envelope(&e.to_string()))?
        .ok_or_else(not_found)?;
    Ok(Json(model_view(
        &guard,
        recipe,
        &row,
        available,
        reclaimable,
        cluster_available,
        residency_known,
        state
            .engine
            .manager
            .as_ref()
            .map(|engine| engine.system_reserve_bytes(recipe))
            .unwrap_or(recipe.memory.minimum_system_reserve_bytes),
    )))
}

#[cfg(test)]
#[path = "models/catalogue_fallback_tests.rs"]
mod catalogue_fallback_tests;

mod inventory;
pub use inventory::{LiveModelInventory, ModelInventory, load_root_key};

mod presentation;
use presentation::model_view;
pub(crate) use presentation::supported_idle_policies;

mod removal;
pub use removal::{RemoveModelBody, preview_remove_model, remove_model};

mod unverified_import;
pub use unverified_import::{ImportUnverifiedRequest, import_unverified_model};
