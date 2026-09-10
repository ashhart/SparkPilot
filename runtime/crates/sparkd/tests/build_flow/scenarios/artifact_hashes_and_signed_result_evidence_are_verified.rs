#[test]
fn artifact_hashes_and_signed_result_evidence_are_verified() {
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
    let bytes = b"typed xcresult evidence";
    let mut artifact = BuildArtifactEvidence {
        artifact_id: Uuid::new_v4(),
        kind: "xcresult".into(),
        relative_path: "result/App.xcresult".into(),
        sha256: "00".repeat(32),
        size_bytes: bytes.len() as u64,
    };
    assert_eq!(
        harness.service.store_artifact(
            &build,
            &worker,
            &claim.lease.claim_token,
            &claim.lease.artifact_token,
            &artifact,
            bytes,
        ),
        Err("BUILD_ARTIFACT_INVALID")
    );
    artifact.sha256 = sha256_hex(bytes);
    let orphaned_upload = harness
        ._directory
        .path()
        .join("build-work/builds")
        .join(build.to_string())
        .join(claim.recipe.payload.claim_generation.to_string())
        .join("artifacts");
    std::fs::create_dir_all(&orphaned_upload).unwrap();
    std::fs::write(
        orphaned_upload.join(artifact.artifact_id.to_string()),
        bytes,
    )
    .unwrap();
    for _ in 0..2 {
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
    }
    let key = p256::ecdsa::SigningKey::from_slice(&[11; 32]).unwrap();
    let mut result = signed_result(&key, &claim, &claim.recipe.payload.issued_at);
    result.evidence.artifacts = vec![artifact];
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
        "completed"
    );
}
