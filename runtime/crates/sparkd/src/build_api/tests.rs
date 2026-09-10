use axum::body::Body;
use axum::extract::FromRequest as _;
use axum::http::Request;

use super::SubmitBuildBody;

#[tokio::test]
async fn submit_build_accepts_the_contracts_exact_http_wire_keys() {
    let project_id = uuid::Uuid::new_v4();
    let body = format!(
        r#"{{"projectId":"{project_id}","commit":"{}","source_sha256":"{}","timeout_seconds":600}}"#,
        "a".repeat(40),
        "b".repeat(64),
    );
    let request = Request::builder()
        .method("POST")
        .uri("/api/v1/builds")
        .header("content-type", "application/json")
        .body(Body::from(body))
        .unwrap();
    let axum::Json(parsed) = axum::Json::<SubmitBuildBody>::from_request(request, &())
        .await
        .expect("the documented JSON wire shape must deserialize");
    assert_eq!(parsed.project_id, project_id);
    assert_eq!(parsed.source_sha256, "b".repeat(64));
    assert_eq!(parsed.timeout_seconds, Some(600));
}
