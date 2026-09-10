#[test]
fn image_preparation_accepts_only_a_digest_pinned_reference() {
    let backend = DockerBackend::new("docker", true);
    let good = backend
        .execute(&PrivilegedOperation::EnsureEngineImage {
            request_id: Uuid::new_v4(),
            image_digest: format!("vllm/vllm-openai@sha256:{}", "c".repeat(64)),
        })
        .unwrap();
    assert!(good.accepted);
    assert_eq!(good.code, "planned");

    let bad = backend.execute(&PrivilegedOperation::EnsureEngineImage {
        request_id: Uuid::new_v4(),
        image_digest: "vllm/vllm-openai:latest".into(),
    });
    assert!(matches!(bad, Err(BackendError::InvalidInput(_))));
}
