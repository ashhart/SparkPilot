#[test]
fn cancellation_acknowledgement_removes_generation_artifacts() {
    let harness = harness();
    let worker = Uuid::new_v4();
    harness
        .service
        .register_worker(
            "Owner",
            &harness.owner,
            "18.0",
            "macOS 27",
            &capabilities(1),
            Some(worker),
        )
        .unwrap();
    let build = submit(&harness, &BuildRequirements::default());
    let claim = harness
        .service
        .claim_next(&worker, &harness.owner, &Uuid::new_v4())
        .unwrap()
        .unwrap();
    let bytes = b"cancelled diagnostic";
    let artifact = BuildArtifactEvidence {
        artifact_id: Uuid::new_v4(),
        kind: "diagnostic".into(),
        relative_path: "diagnostics/cancelled.txt".into(),
        sha256: sha256_hex(bytes),
        size_bytes: bytes.len() as u64,
    };
    harness
        .service
        .store_artifact(
            &build,
            &worker,
            &claim.lease.claim_token,
            &claim.lease.artifact_token,
            &artifact,
            bytes,
        )
        .unwrap();
    let generation_dir = harness
        ._directory
        .path()
        .join("build-work/builds")
        .join(build.to_string())
        .join(claim.recipe.payload.claim_generation.to_string());
    assert!(generation_dir.exists());
    let operation_id = harness.service.get_build(&build).unwrap().operation_id;
    harness
        .service
        .jobs
        .cancel_requested(&harness.service.projects.db.lock(), operation_id)
        .unwrap();
    let key = p256::ecdsa::SigningKey::from_slice(&[15; 32]).unwrap();
    let mut result = signed_result(&key, &claim, &claim.recipe.payload.issued_at);
    result.evidence.exit_state = "cancelled".into();
    let signature: p256::ecdsa::Signature =
        key.sign(&sparkd::build_protocol::canonical_json(&result.evidence).unwrap());
    result.worker_signature = base64url_encode(signature.to_bytes().as_ref());

    assert_eq!(
        harness
            .service
            .record_result(
                &build,
                &worker,
                &claim.lease.claim_token,
                &spki(&key),
                &result,
            )
            .unwrap()
            .status,
        "cancelled"
    );
    assert!(!generation_dir.exists());
    let conn = harness.service.projects.db.lock();
    assert!(
        store::build_artifacts(&conn, &build, claim.recipe.payload.claim_generation)
            .unwrap()
            .is_empty()
    );
}
