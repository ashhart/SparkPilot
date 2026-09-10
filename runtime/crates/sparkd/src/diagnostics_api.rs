//! Describe export options from runtime policy and return bundles without server-side files or replay copies.

use axum::extract::{Extension, State};
use axum::http::{HeaderMap, StatusCode};
use axum::response::Json;
use serde::Deserialize;
use serde_json::{Value, json};

use crate::auth::{AuthenticatedRequest, Principal};
use crate::capability::{Capability, Presence};
use crate::diagnostics;
use crate::state::AppState;

const CATALOGUE_ROUTE: &str = "/api/v1/diagnostics";
const EXPORT_ROUTE: &str = "/api/v1/diagnostics/export";

#[derive(Debug, Default, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ExportRequest {
    /// Owner-selected sensitive categories; absence requests only the default bundle.
    #[serde(default)]
    pub include_optional: Vec<String>,
}

fn envelope(status: StatusCode, code: &str, message: &str) -> (StatusCode, Json<Value>) {
    (
        status,
        Json(json!({
            "error": {
                "code": code,
                "message": message,
                "request_id": uuid::Uuid::new_v4().to_string(),
            }
        })),
    )
}

/// Treat invalid presence as absent and let the capability evaluator deny and audit the export.
fn verified_presence(
    state: &AppState,
    principal: &Principal,
    authenticated_request: &AuthenticatedRequest,
    headers: &HeaderMap,
) -> Result<Presence, (StatusCode, Json<Value>)> {
    let Some(database) = state.database.as_ref() else {
        return Err(envelope(
            StatusCode::INTERNAL_SERVER_ERROR,
            "INTERNAL_ERROR",
            "no database",
        ));
    };
    let presence_key = {
        let connection = database.lock();
        // The store error is not logged: it names the database file.
        crate::store::load_presence_key_by_device_id(&connection, &principal.device_id).map_err(
            |_| {
                tracing::error!("presence key lookup failed");
                envelope(
                    StatusCode::INTERNAL_SERVER_ERROR,
                    "INTERNAL_ERROR",
                    "presence key lookup failed",
                )
            },
        )?
    };
    Ok(
        match crate::user_presence::verify(
            headers.get(crate::user_presence::HEADER_USER_PRESENCE),
            presence_key.as_deref(),
            authenticated_request,
            state.clock.now(),
        ) {
            Ok(()) => Presence::Fresh,
            Err(_) => Presence::Absent,
        },
    )
}

/// Describe the bundle before export.
pub async fn get_catalogue(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    state
        .require(&principal, Capability::DiagnosticsRead)
        .resource(CATALOGUE_ROUTE)
        .check()?;

    Ok(Json(json!({
        "observed_at": state.clock.now_rfc3339(),
        "sections": diagnostics::DEFAULT_SECTIONS,
        "optional_categories": diagnostics::OPTIONAL_SECTIONS,
        "never_exported": diagnostics::NEVER_EXPORTED,
    })))
}

/// Produce one bundle for one explicit owner action.
pub async fn export(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    Extension(authenticated_request): Extension<AuthenticatedRequest>,
    headers: HeaderMap,
    body: Option<Json<ExportRequest>>,
) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    let request = body.map(|Json(request)| request).unwrap_or_default();

    // Verify the enrolled presence key before one authorization decision so missing presence records a refusal, never a misleading acceptance.
    let presence = verified_presence(&state, &principal, &authenticated_request, &headers)?;

    // Authorize before validating selection so error differences cannot enumerate categories to unauthorized callers.
    state
        .require(&principal, Capability::DiagnosticsExport)
        .resource(EXPORT_ROUTE)
        .details(json!({ "requested_optional_count": request.include_optional.len() }))
        .check_with_verified_presence(presence)?;

    // Do not echo attacker-supplied rejected category IDs.
    let selected = diagnostics::resolve_selection(&request.include_optional).map_err(|_| {
        envelope(
            StatusCode::BAD_REQUEST,
            "DIAGNOSTICS_CATEGORY_UNKNOWN",
            "this runtime does not offer one of the requested optional categories",
        )
    })?;

    let bundle = diagnostics::build(&state, &selected).await;

    // Audit exported category IDs without retaining their content.
    if let Some(database) = state.database.as_ref() {
        let details = json!({ "optional_included": selected.iter().collect::<Vec<_>>() });
        let draft = crate::audit::AuditDraft {
            actor_device_id: Some(principal.device_id),
            actor_role: Some(&principal.role),
            source_route: EXPORT_ROUTE,
            action: "diagnostics.export.completed",
            resource: Some(EXPORT_ROUTE),
            result: "accepted",
            operation_id: None,
            request_id: None,
            details: &details,
        };
        crate::audit::append_committed(database, state.clock.as_ref(), &draft)
            .map_err(crate::audit::unavailable_envelope)?;
    }
    // Suppress serialization error details because they may identify bundle contents.
    serde_json::to_value(bundle).map(Json).map_err(|_| {
        tracing::error!("diagnostics bundle could not be encoded");
        envelope(
            StatusCode::INTERNAL_SERVER_ERROR,
            "INTERNAL_ERROR",
            "the bundle could not be encoded",
        )
    })
}
