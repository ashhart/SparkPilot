//! Prove PLAN §19.5 step 1: a panicking handler becomes a typed 500 that leaks no panic payload.

use axum::Router;
use axum::body::{Body, to_bytes};
use axum::http::{Request, StatusCode};
use axum::routing::get;
use serde_json::Value;
use tower::ServiceExt;

/// The panic payload names a fake secret so a leak is visible in the assertion rather than implied.
async fn panicking_handler() -> &'static str {
    panic!("handler exploded while holding hf_secret_token_value");
}

#[tokio::test]
async fn a_panicking_handler_returns_a_typed_error_instead_of_dropping_the_connection() {
    let app = sparkd::route::correlated(
        Router::new().route("/api/v1/panic-probe", get(panicking_handler)),
    );

    let response = app
        .oneshot(
            Request::builder()
                .uri("/api/v1/panic-probe")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .expect("a contained panic must still produce a response");

    assert_eq!(response.status(), StatusCode::INTERNAL_SERVER_ERROR);
    assert_eq!(
        response
            .headers()
            .get(sparkd::route::API_VERSION_HEADER)
            .and_then(|value| value.to_str().ok()),
        Some(sparkd::route::API_MAJOR_VERSION),
        "a contained panic still carries the API version header"
    );
    assert_eq!(
        response
            .headers()
            .get(axum::http::header::CONTENT_TYPE)
            .and_then(|value| value.to_str().ok()),
        Some("application/json"),
    );

    let body = to_bytes(response.into_body(), 64 * 1024).await.unwrap();
    let envelope: Value = serde_json::from_slice(&body).unwrap();
    assert_eq!(envelope["error"]["code"], "INTERNAL_ERROR");
    assert!(
        envelope["error"]["request_id"]
            .as_str()
            .is_some_and(|id| uuid::Uuid::parse_str(id).is_ok()),
        "the envelope carries a request id for support: {envelope}"
    );

    let text = String::from_utf8(body.to_vec()).unwrap();
    assert!(
        !text.contains("hf_secret_token_value") && !text.contains("exploded"),
        "the panic payload must never reach the client: {text}"
    );
}

#[tokio::test]
async fn a_contained_panic_reuses_the_correlated_request_id() {
    let app = sparkd::route::correlated(
        Router::new().route("/api/v1/panic-probe", get(panicking_handler)),
    );

    let supplied = uuid::Uuid::from_u128(0x5041_4e49_4300_0000_0000_0000_0000_0001).to_string();
    let response = app
        .oneshot(
            Request::builder()
                .uri("/api/v1/panic-probe")
                .header("x-request-id", supplied.clone())
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(
        response
            .headers()
            .get("x-request-id")
            .and_then(|value| value.to_str().ok()),
        Some(supplied.as_str()),
    );
    let body = to_bytes(response.into_body(), 64 * 1024).await.unwrap();
    let envelope: Value = serde_json::from_slice(&body).unwrap();
    assert_eq!(
        envelope["error"]["request_id"], supplied,
        "support can join the log line to the response"
    );
}
