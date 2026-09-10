#[test]
fn claim_is_acl_capability_concurrency_and_recipe_bound() {
    let harness = harness();
    let requirements = BuildRequirements {
        sdk: Some("macosx".into()),
        signing_required: true,
        ..Default::default()
    };
    submit(&harness, &requirements);
    let stranger = Uuid::new_v4();
    let stranger_worker = Uuid::new_v4();
    {
        let connection = harness.service.projects.db.lock();
        let key = p256::ecdsa::SigningKey::from_slice(&[5; 32]).unwrap();
        store::insert_device(
            &connection,
            &stranger,
            "Stranger Mac",
            "macos",
            &spki(&key),
            "stranger-test-fingerprint",
            "developer",
        )
        .unwrap();
    }
    harness
        .service
        .register_worker(
            "Stranger",
            &stranger,
            "18.0",
            "macOS 27",
            &capabilities(1),
            Some(stranger_worker),
        )
        .unwrap();
    assert!(
        harness
            .service
            .claim_next(&stranger_worker, &stranger, &Uuid::new_v4())
            .unwrap()
            .is_none()
    );
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
    let claim = harness
        .service
        .claim_next(&worker, &harness.owner, &Uuid::new_v4())
        .unwrap()
        .unwrap();
    claim.recipe.verify(&harness.public_identity).unwrap();
    let issued = time::OffsetDateTime::parse(
        &claim.recipe.payload.issued_at,
        &time::format_description::well_known::Rfc3339,
    )
    .unwrap();
    claim
        .recipe
        .verify_for(&harness.public_identity, worker, issued)
        .unwrap();
    assert_eq!(
        claim
            .recipe
            .verify_for(&harness.public_identity, Uuid::new_v4(), issued),
        Err("BUILD_RECIPE_BINDING_MISMATCH")
    );
    let expired = time::OffsetDateTime::parse(
        &claim.recipe.payload.expires_at,
        &time::format_description::well_known::Rfc3339,
    )
    .unwrap()
        + time::Duration::seconds(1);
    assert_eq!(
        claim
            .recipe
            .verify_for(&harness.public_identity, worker, expired),
        Err("BUILD_RECIPE_EXPIRED")
    );
    assert_eq!(
        (
            claim.recipe.payload.worker_id,
            claim.recipe.payload.project_id
        ),
        (worker, harness.project.id)
    );
    assert_eq!(
        (
            claim.recipe.payload.commit.as_str(),
            claim.recipe.payload.source_sha256.as_str()
        ),
        (COMMIT, SOURCE)
    );
    assert_eq!(
        claim.recipe.payload.artifact_ticket.max_file_bytes,
        MAX_ARTIFACT_BYTES
    );
    assert_eq!(
        claim.recipe.payload.artifact_ticket.max_total_bytes,
        MAX_ARTIFACT_TOTAL_BYTES
    );
    assert_eq!(
        claim.recipe.payload.artifact_ticket.max_files,
        MAX_ARTIFACTS
    );
    let mut tampered = claim.recipe.clone();
    tampered.payload.worker_id = Uuid::new_v4();
    assert_eq!(
        tampered.verify(&harness.public_identity),
        Err("BUILD_RECIPE_TAMPERED")
    );
    submit(&harness, &requirements);
    assert_eq!(
        harness
            .service
            .claim_next(&worker, &harness.owner, &Uuid::new_v4()),
        Err("BUILD_WORKER_AT_CAPACITY".into())
    );
}
