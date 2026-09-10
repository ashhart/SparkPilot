#[tokio::test]
async fn result_artifact_evidence_is_bijective_and_download_is_authorized_and_digest_checked() {
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
    let mut artifacts = Vec::new();
    for (name, bytes) in [
        ("one.png", b"one".as_slice()),
        ("two.png", b"two".as_slice()),
    ] {
        let artifact = BuildArtifactEvidence {
            artifact_id: Uuid::new_v4(),
            kind: "screenshot".into(),
            relative_path: format!("screenshots/{name}"),
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
        artifacts.push((artifact, bytes.to_vec()));
    }
    let key = p256::ecdsa::SigningKey::from_slice(&[13; 32]).unwrap();
    let mut duplicate = signed_result(&key, &claim, &claim.recipe.payload.issued_at);
    duplicate.evidence.artifacts = vec![artifacts[0].0.clone(), artifacts[0].0.clone()];
    let signature: p256::ecdsa::Signature =
        key.sign(&sparkd::build_protocol::canonical_json(&duplicate.evidence).unwrap());
    duplicate.worker_signature = base64url_encode(signature.to_bytes().as_ref());
    assert_eq!(
        harness
            .service
            .record_result(
                &build,
                &worker,
                &claim.lease.claim_token,
                &spki(&key),
                &duplicate,
            )
            .unwrap_err(),
        "BUILD_ARTIFACT_INVALID"
    );
    let mut result = signed_result(&key, &claim, &claim.recipe.payload.issued_at);
    result.evidence.artifacts = artifacts.iter().map(|item| item.0.clone()).collect();
    let signature: p256::ecdsa::Signature =
        key.sign(&sparkd::build_protocol::canonical_json(&result.evidence).unwrap());
    result.worker_signature = base64url_encode(signature.to_bytes().as_ref());
    harness
        .service
        .record_result(
            &build,
            &worker,
            &claim.lease.claim_token,
            &spki(&key),
            &result,
        )
        .unwrap();
    let (_, downloaded) = harness
        .service
        .read_artifact(&build, &artifacts[0].0.artifact_id)
        .unwrap();
    assert_eq!(downloaded, artifacts[0].1);

    let path = format!(
        "/api/v1/builds/{build}/artifacts/{}",
        artifacts[0].0.artifact_id
    );
    let owner_key = p256::ecdsa::SigningKey::from_slice(&[3; 32]).unwrap();
    let response = router(harness.state.clone())
        .oneshot(signed_get(&owner_key, harness.owner, &path))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(
        response.headers()["x-spark-artifact-sha256"],
        artifacts[0].0.sha256
    );
    assert_eq!(response.headers()["cache-control"], "private, no-store");
    assert_eq!(
        to_bytes(response.into_body(), MAX_ARTIFACT_BYTES as usize)
            .await
            .unwrap(),
        artifacts[0].1
    );

    let stranger_key = p256::ecdsa::SigningKey::from_slice(&[17; 32]).unwrap();
    let stranger = Uuid::new_v4();
    store::insert_device(
        &harness.state.database.as_ref().unwrap().lock(),
        &stranger,
        "Unrelated developer",
        "macos",
        &spki(&stranger_key),
        "unrelated-fingerprint",
        "developer",
    )
    .unwrap();
    let denied = router(harness.state.clone())
        .oneshot(signed_get(&stranger_key, stranger, &path))
        .await
        .unwrap();
    assert_eq!(denied.status(), StatusCode::NOT_FOUND);
}
