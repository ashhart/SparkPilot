//! Shared HTTP error envelopes for cross-resource failures.

use axum::extract::Request;
use axum::http::StatusCode;
use axum::http::header::CONTENT_TYPE;
use axum::middleware::Next;
use axum::response::{IntoResponse, Json, Response};
use serde_json::{Value, json};

use crate::jobs::LeaseError;

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

/// Limit echoed field names to 48 characters so errors cannot amplify request payloads.
pub fn abbreviated(value: &str) -> String {
    const KEEP: usize = 48;
    if value.chars().count() <= KEEP {
        return value.to_owned();
    }
    let head: String = value.chars().take(KEEP).collect();
    format!("{head}…")
}

/// Replace framework plain-text refusals with fixed typed envelopes that never echo attacker-controlled extractor details.
pub async fn typed_refusals(request: Request, next: Next) -> Response {
    let response = next.run(request).await;
    let status = response.status();
    let plain_text = response
        .headers()
        .get(CONTENT_TYPE)
        .and_then(|value| value.to_str().ok())
        .is_some_and(|value| value.starts_with("text/plain"));
    if !status.is_client_error() || !plain_text {
        return response;
    }
    let (code, message) = match status {
        StatusCode::PAYLOAD_TOO_LARGE => (
            "REQUEST_TOO_LARGE",
            "the request body is larger than this endpoint accepts",
        ),
        StatusCode::UNSUPPORTED_MEDIA_TYPE => (
            "REQUEST_UNSUPPORTED_MEDIA_TYPE",
            "this endpoint accepts application/json",
        ),
        StatusCode::METHOD_NOT_ALLOWED => (
            "METHOD_NOT_ALLOWED",
            "this path does not accept that method",
        ),
        _ => (
            "REQUEST_INVALID",
            "the request body is not the shape this endpoint accepts",
        ),
    };
    // Preserve existing response headers, including version, retry timing and request ID.
    let (mut parts, _discarded) = response.into_parts();
    let (replacement, body) = envelope(status, code, message).into_response().into_parts();
    parts.headers.remove(axum::http::header::CONTENT_LENGTH);
    for (name, value) in &replacement.headers {
        parts.headers.insert(name, value.clone());
    }
    Response::from_parts(parts, body)
}

/// Map worker saturation to retryable HTTP 503 rather than an internal-error diagnosis.
pub fn spawn_envelope(error: &LeaseError) -> (StatusCode, Json<Value>) {
    match error {
        LeaseError::Overloaded(capacity) => {
            tracing::warn!(capacity, "operation refused: all workers are busy");
            envelope(
                StatusCode::SERVICE_UNAVAILABLE,
                "OPERATION_CAPACITY_EXCEEDED",
                &format!(
                    "all {capacity} operation workers are busy; retry after running work completes"
                ),
            )
        }
        LeaseError::Held => envelope(
            StatusCode::CONFLICT,
            "OPERATION_IN_PROGRESS",
            "another worker already holds this operation",
        ),
        other => {
            tracing::error!(error = %other, "operation worker could not start");
            envelope(
                StatusCode::INTERNAL_SERVER_ERROR,
                "INTERNAL",
                &other.to_string(),
            )
        }
    }
}

#[cfg(test)]
mod tests {
    use axum::Router;
    use axum::body::Body;
    use axum::routing::get;
    use tower::ServiceExt;

    use super::*;

    /// Inspect only response headers so error rewriting never buffers streaming bodies.
    #[tokio::test]
    async fn a_streaming_response_is_not_collected_by_the_rewrite() {
        let (sender, receiver) = tokio::sync::mpsc::channel::<Result<Vec<u8>, std::io::Error>>(1);
        let receiver = std::sync::Arc::new(parking_lot::Mutex::new(Some(receiver)));
        let app = Router::new()
            .route(
                "/stream",
                get(move || {
                    let receiver = receiver.lock().take().expect("one call");
                    async move {
                        Response::builder()
                            .status(StatusCode::OK)
                            .header(CONTENT_TYPE, "text/plain")
                            .body(Body::from_stream(
                                tokio_stream::wrappers::ReceiverStream::new(receiver),
                            ))
                            .unwrap()
                    }
                }),
            )
            .layer(axum::middleware::from_fn(typed_refusals));

        let response = app
            .oneshot(
                Request::builder()
                    .uri("/stream")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        // Receiving headers before body completion proves the stream was not collected.
        assert_eq!(response.status(), StatusCode::OK);
        sender.send(Ok(b"first".to_vec())).await.unwrap();
        drop(sender);
        let body = axum::body::to_bytes(response.into_body(), 1 << 16)
            .await
            .unwrap();
        assert_eq!(&body[..], b"first");
    }

    /// Preserve handlers' existing typed 4xx envelopes.
    #[tokio::test]
    async fn a_json_refusal_passes_through_untouched() {
        let app = Router::new()
            .route(
                "/refuse",
                get(|| async {
                    envelope(StatusCode::CONFLICT, "OPERATION_IN_PROGRESS", "held").into_response()
                }),
            )
            .layer(axum::middleware::from_fn(typed_refusals));
        let response = app
            .oneshot(
                Request::builder()
                    .uri("/refuse")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::CONFLICT);
        let body = axum::body::to_bytes(response.into_body(), 1 << 16)
            .await
            .unwrap();
        let value: Value = serde_json::from_slice(&body).unwrap();
        assert_eq!(value["error"]["code"], "OPERATION_IN_PROGRESS");
    }

    #[test]
    fn an_abbreviated_name_is_bounded_and_stays_on_a_character_boundary() {
        assert_eq!(abbreviated("short"), "short");
        let long = "é".repeat(4096);
        let cut = abbreviated(&long);
        assert!(
            cut.chars().count() <= 49,
            "{} characters",
            cut.chars().count()
        );
        assert!(cut.ends_with('…'));
    }
}
