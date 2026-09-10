#[test]
fn image_readiness_requires_the_exact_typed_response_shape() {
    let request_id = uuid::Uuid::new_v4();
    let digest = "registry.example/vllm@sha256:0123456789abcdef";
    let valid = PrivilegedResponse {
        request_id,
        accepted: true,
        code: "image_ready".into(),
        message: "ready".into(),
        details: json!({ "image_digest": digest, "pulled": true }),
    };
    assert!(validate_engine_image_readiness(request_id, digest, &valid).is_ok());

    let mut invalid = valid.clone();
    invalid.request_id = uuid::Uuid::new_v4();
    assert!(validate_engine_image_readiness(request_id, digest, &invalid).is_err());
    let mut invalid = valid.clone();
    invalid.accepted = false;
    assert!(validate_engine_image_readiness(request_id, digest, &invalid).is_err());
    let mut invalid = valid.clone();
    invalid.code = "pulled".into();
    assert!(validate_engine_image_readiness(request_id, digest, &invalid).is_err());
    let mut invalid = valid.clone();
    invalid.details["image_digest"] = json!("another-image");
    assert!(validate_engine_image_readiness(request_id, digest, &invalid).is_err());
    let mut invalid = valid;
    invalid.details["pulled"] = json!("false");
    assert!(validate_engine_image_readiness(request_id, digest, &invalid).is_err());
}
