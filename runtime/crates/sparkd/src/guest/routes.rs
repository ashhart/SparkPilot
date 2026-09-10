//! Hold a guest to a named list of routes, so anything added to the API later is closed to guests until someone opens it.

use axum::extract::Request;
use axum::http::{Method, StatusCode};
use axum::middleware::Next;
use axum::response::{IntoResponse, Response};

use crate::auth::Principal;
use crate::capability::Role;

/// Every route a guest may reach. Method and path must both match.
pub const GUEST_ROUTES: &[(&str, &str)] = &[
    ("GET", "/api/v1/health"),
    ("GET", "/api/v1/identity"),
    ("GET", "/api/v1/status"),
    ("GET", "/api/v1/capabilities"),
    ("GET", "/api/v1/shared-access/self"),
    ("GET", "/api/v1/household/notes"),
    ("POST", "/api/v1/household/notes"),
    ("GET", "/v1/models"),
    ("POST", "/v1/chat/completions"),
    ("POST", "/v1/responses"),
];

/// Whether a guest may reach this method and path at all.
pub fn guest_may_reach(method: &Method, path: &str) -> bool {
    GUEST_ROUTES.iter().any(|(allowed_method, allowed_path)| {
        *allowed_method == method.as_str() && *allowed_path == path
    })
}

/// Refuse every route a guest is not explicitly given, before the handler runs.
pub async fn restrict_guest_routes(request: Request, next: Next) -> Response {
    let is_guest = request
        .extensions()
        .get::<Principal>()
        .is_some_and(|principal| Role::parse(&principal.role) == Role::Guest);
    if is_guest && !guest_may_reach(request.method(), request.uri().path()) {
        return (
            StatusCode::FORBIDDEN,
            axum::Json(serde_json::json!({
                "error": {
                    "code": "ROLE_FORBIDDEN",
                    "message": "shared access does not include this",
                    "request_id": crate::route::current_request_id(),
                }
            })),
        )
            .into_response();
    }
    next.run(request).await
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_guest_route_list_covers_chat_and_the_guests_own_record_only() {
        assert!(guest_may_reach(&Method::POST, "/v1/chat/completions"));
        assert!(guest_may_reach(&Method::GET, "/api/v1/shared-access/self"));
        for path in [
            "/api/v1/settings",
            "/api/v1/devices",
            "/api/v1/models",
            "/api/v1/telemetry",
            "/api/v1/shared-access",
            "/api/v1/events",
            "/api/v1/inference/requests",
        ] {
            assert!(
                !guest_may_reach(&Method::GET, path),
                "{path} must not be open to a guest"
            );
        }
        assert!(
            !guest_may_reach(&Method::POST, "/api/v1/shared-access/self"),
            "the method matters as much as the path"
        );
    }
}
