#[test]
fn rejected_engine_image_fails_the_operation_without_installing_the_model() {
    let directory = tempfile::tempdir().unwrap();
    let socket = directory.path().join("spark-privd.sock");
    let (privileged, observed) =
        image_readiness_responder(&socket, ImageReadinessReply::Rejected);
    let (state, recipe, operation_id) = image_install_state(directory.path(), privileged);

    spawn_install_worker(&state, operation_id, recipe.id(), None).unwrap();

    let operation = observed
        .recv_timeout(std::time::Duration::from_secs(5))
        .expect("engine image request");
    assert!(matches!(
        operation,
        PrivilegedOperation::EnsureEngineImage { image_digest, .. }
            if image_digest == recipe.engine.image
    ));
    let terminal = wait_for_image_install(&state, operation_id);
    assert_eq!(terminal.state, "failed");
    assert_eq!(
        terminal.error_code.as_deref(),
        Some("MODEL_ENGINE_IMAGE_UNAVAILABLE")
    );
    let model = crate::store::model_row(&state.database.as_ref().unwrap().lock(), recipe.id())
        .unwrap()
        .unwrap();
    assert_eq!(model.install_state, "available");
}
