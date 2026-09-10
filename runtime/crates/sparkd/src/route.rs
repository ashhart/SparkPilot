//! Apply panic containment and request correlation before protected authentication; health and pairing remain narrowly public.

use std::net::SocketAddr;
use std::time::Duration;

use axum::Router;
use axum::extract::connect_info::IntoMakeServiceWithConnectInfo;
use axum::http::{HeaderName, HeaderValue};
use axum::middleware;
use axum::response::IntoResponse;
use axum::routing::{get, post};
use tower_http::catch_panic::CatchPanicLayer;
use tower_http::request_id::{MakeRequestUuid, PropagateRequestIdLayer, SetRequestIdLayer};
use tower_http::set_header::SetResponseHeaderLayer;
use tower_http::trace::TraceLayer;

use crate::agent_api;
use crate::analysis_api;
use crate::appliance_api;
use crate::auth;
use crate::automations_api;
use crate::build_api;
use crate::catalogue_api;
use crate::cluster_api;
use crate::diagnostics_api;
use crate::download_api;
use crate::engine_api;
use crate::handlers;
use crate::models;
use crate::network_api;
use crate::power_api;
use crate::profile_api;
use crate::project_api;
use crate::remote_api;
use crate::service_api;
use crate::state::AppState;
use crate::system_api;
use crate::telemetry_api;
use crate::workload_adoption;
use crate::workload_api;

/// Header carrying the per-request correlation id.
pub(crate) const REQUEST_ID_HEADER: &str = "x-request-id";

tokio::task_local! {
    /// Use one request id in response headers, error envelopes and trace spans for reliable support correlation.
    static REQUEST_ID: String;
}

/// Return the scoped request id, or generate a UUID outside request scope.
pub fn current_request_id() -> String {
    REQUEST_ID
        .try_with(|id| id.clone())
        .unwrap_or_else(|_| uuid::Uuid::new_v4().to_string())
}

/// Bind the assigned request id before handlers and timeout errors so every response envelope agrees.
async fn scope_request_id(
    request: axum::extract::Request,
    next: axum::middleware::Next,
) -> axum::response::Response {
    let id = request
        .headers()
        .get(REQUEST_ID_HEADER)
        .and_then(|value| value.to_str().ok())
        .map(str::to_owned)
        .unwrap_or_else(|| uuid::Uuid::new_v4().to_string());
    REQUEST_ID.scope(id, next.run(request)).await
}

/// §58.1: the API major version carried on every response.
pub const API_VERSION_HEADER: &str = "x-spark-api-version";
/// Changing the implemented major version requires an explicit API-version migration.
pub const API_MAJOR_VERSION: &str = "1";

/// Attach real peer addresses to production requests so public and failed-auth budgets cannot collapse into an unattributed global bucket.
pub fn socket_service(app: Router) -> IntoMakeServiceWithConnectInfo<Router, SocketAddr> {
    app.into_make_service_with_connect_info::<SocketAddr>()
}

pub fn router(state: AppState) -> Router {
    router_with_request_timeout(state, Duration::from_secs(30))
}

pub fn router_with_request_timeout(state: AppState, request_timeout: Duration) -> Router {
    // Keep health and the initial pairing handshake public because they precede any device grant.
    let public = Router::new()
        .route(
            "/api/v1/pairing/join-codes/exchange",
            post(crate::pairing_code_exchange::exchange)
                .layer(axum::extract::DefaultBodyLimit::max(1024)),
        )
        .route("/api/v1/health", get(handlers::health))
        .route(
            "/api/v1/pairing/challenge",
            post(handlers::pairing_challenge),
        )
        .route("/api/v1/pairing/claim", post(handlers::pairing_claim))
        .route(
            "/api/v1/pairing/join-codes/redeem",
            post(handlers::redeem_join_code),
        )
        .route(
            "/services/open-webui/",
            get(service_api::open_webui_redirect),
        )
        // Charge unauthenticated requests, including pairing attempts, to the real source-address budget.
        .route_layer(middleware::from_fn_with_state(
            state.clone(),
            crate::ratelimit::limit,
        ))
        .with_state(state.clone());

    // Protected: everything else requires a valid device signature and role.
    let protected = Router::new()
        .merge(protected_routes::identity())
        .merge(protected_routes::observation())
        .merge(protected_routes::workloads())
        .merge(protected_routes::network())
        .merge(protected_routes::settings())
        .merge(protected_routes::automations())
        .merge(protected_routes::catalogue())
        .merge(protected_routes::services())
        .merge(protected_routes::pairing())
        .merge(protected_routes::shared_access())
        .route(
            "/api/v1/household/notes",
            get(crate::household::snapshot).post(crate::household::save_note),
        )
        .route(
            "/api/v1/household/members",
            post(crate::household::set_member),
        )
        .merge(protected_routes::models())
        .merge(protected_routes::activity())
        .merge(protected_routes::cluster())
        .merge(protected_routes::fabric())
        .merge(protected_routes::remote())
        .merge(protected_routes::power())
        .merge(protected_routes::system())
        .merge(protected_routes::storage())
        .merge(protected_routes::credentials())
        .merge(protected_routes::inference())
        .merge(protected_routes::build_workers())
        .merge(protected_routes::builds())
        .merge(protected_routes::projects())
        .layer(axum::extract::DefaultBodyLimit::max(16 * 1024 * 1024))
        // Run authentication before device rate limiting and handler authorization so only verified grants select device budgets.
        .route_layer(middleware::from_fn_with_state(
            state.clone(),
            crate::ratelimit::limit,
        ))
        .route_layer(middleware::from_fn(crate::guest::restrict_guest_routes))
        .route_layer(middleware::from_fn_with_state(
            state.clone(),
            auth::require_authentication,
        ))
        .with_state(state.clone());

    // Let cluster phases use their typed deadlines and durable fences rather than abandoning them at the ordinary HTTP timeout.
    let cluster_operations = Router::new()
        .route(
            "/api/v1/cluster/transactions/prepare",
            post(cluster_api::prepare_cluster_transaction),
        )
        .route(
            "/api/v1/cluster/transactions/activate",
            post(cluster_api::activate_cluster_transaction),
        )
        .route(
            "/api/v1/cluster/transactions/prove",
            post(cluster_api::prove_cluster_transaction),
        )
        .route(
            "/api/v1/cluster/transactions/collective",
            post(cluster_api::run_cluster_collective),
        )
        .route(
            "/api/v1/cluster/transactions/commit",
            post(cluster_api::commit_cluster_transaction),
        )
        .route(
            "/api/v1/cluster/transactions/finalize",
            post(cluster_api::finalize_cluster_transaction),
        )
        .route(
            "/api/v1/cluster/transactions/rollback",
            post(cluster_api::rollback_cluster_transaction),
        )
        .route(
            "/api/v1/cluster/launches",
            get(cluster_api::get_cluster_launches).post(cluster_api::start_cluster_launch),
        )
        .route(
            "/api/v1/cluster/launches/{launch_id}",
            get(cluster_api::get_cluster_launch),
        )
        .route(
            "/api/v1/cluster/launches/{launch_id}/stop",
            post(cluster_api::stop_cluster_launch),
        )
        .layer(axum::extract::DefaultBodyLimit::max(16 * 1024 * 1024))
        .route_layer(middleware::from_fn_with_state(
            state.clone(),
            crate::ratelimit::limit,
        ))
        .route_layer(middleware::from_fn(crate::guest::restrict_guest_routes))
        .route_layer(middleware::from_fn_with_state(
            state.clone(),
            auth::require_authentication,
        ))
        .with_state(state.clone());

    // Keep chat authentication and rate limits while letting cancellation and the engine govern long completion lifetimes.
    let chat = Router::new()
        .route("/v1/audio/speech", post(crate::speech_api::speech))
        .route("/v1/chat/completions", post(engine_api::chat_completions))
        .route("/v1/responses", post(engine_api::openai_responses))
        .layer(axum::extract::DefaultBodyLimit::max(16 * 1024 * 1024))
        .route_layer(middleware::from_fn_with_state(
            state.clone(),
            crate::ratelimit::limit,
        ))
        .route_layer(middleware::from_fn(crate::guest::restrict_guest_routes))
        .route_layer(middleware::from_fn_with_state(
            state.clone(),
            auth::require_authentication,
        ))
        .with_state(state.clone());

    let bounded = Router::new().merge(public).merge(protected).layer(
        tower::ServiceBuilder::new()
            .layer(axum::error_handling::HandleErrorLayer::new(|_| async {
                (
                    axum::http::StatusCode::GATEWAY_TIMEOUT,
                    axum::response::Json(serde_json::json!({
                        "error": {
                            "code": "REQUEST_TIMEOUT",
                            "message": "the request exceeded the server time limit",
                            "request_id": current_request_id(),
                        }
                    })),
                )
            }))
            .timeout(request_timeout),
    );

    correlated(
        Router::new()
            .merge(bounded)
            .merge(chat)
            .merge(cluster_operations),
    )
}

/// §58.4: answer a panic with the catalogued envelope and never the payload, which can hold request data.
fn panic_response(payload: Box<dyn std::any::Any + Send + 'static>) -> axum::response::Response {
    let request_id = current_request_id();
    // Keep the cause in the operator's log under the same request id the caller is given.
    let cause = payload
        .downcast_ref::<String>()
        .map(String::as_str)
        .or_else(|| payload.downcast_ref::<&str>().copied())
        .unwrap_or("panic payload is not a string");
    tracing::error!(%request_id, %cause, "handler panicked; answering with INTERNAL_ERROR");
    (
        axum::http::StatusCode::INTERNAL_SERVER_ERROR,
        axum::response::Json(serde_json::json!({
            "error": {
                "code": "INTERNAL_ERROR",
                "message": "the request could not be completed",
                "request_id": request_id,
            }
        })),
    )
        .into_response()
}

/// §19.5 steps 1-3: contain panics and correlate every response, including one a handler could not produce.
pub fn correlated(app: Router) -> Router {
    let request_id_header = HeaderName::from_static(REQUEST_ID_HEADER);
    app.layer(
        tower::ServiceBuilder::new()
            .layer(middleware::from_fn(crate::api_error::typed_refusals))
            // Attach the API major version at the response layer so errors and timeouts carry it too.
            .layer(SetResponseHeaderLayer::if_not_present(
                HeaderName::from_static(API_VERSION_HEADER),
                HeaderValue::from_static(API_MAJOR_VERSION),
            ))
            .layer(SetRequestIdLayer::new(
                request_id_header.clone(),
                MakeRequestUuid,
            ))
            .layer(PropagateRequestIdLayer::new(request_id_header))
            .layer(TraceLayer::new_for_http())
            .layer(middleware::from_fn(scope_request_id))
            // Innermost of the correlation layers so a contained panic still carries its request id and API version.
            .layer(CatchPanicLayer::custom(
                panic_response as fn(Box<dyn std::any::Any + Send + 'static>) -> _,
            )),
    )
}

mod protected_routes;
