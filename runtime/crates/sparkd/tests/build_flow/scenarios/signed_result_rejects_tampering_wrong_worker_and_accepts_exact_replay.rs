#[test]
fn signed_result_rejects_tampering_wrong_worker_and_accepts_exact_replay() {
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
    harness
        .service
        .renew_claim(&build, &worker, &claim.lease.claim_token)
        .unwrap();
    let key = p256::ecdsa::SigningKey::from_slice(&[7; 32]).unwrap();
    let result = signed_result(&key, &claim, &claim.recipe.payload.issued_at);
    let mut tampered = result.clone();
    tampered.evidence.source_sha256 = "cc".repeat(32);
    assert_eq!(
        harness
            .service
            .record_result(
                &build,
                &worker,
                &claim.lease.claim_token,
                &spki(&key),
                &tampered
            )
            .err(),
        Some("BUILD_RESULT_SIGNATURE_INVALID")
    );
    let signature: p256::ecdsa::Signature =
        key.sign(&sparkd::build_protocol::canonical_json(&tampered.evidence).unwrap());
    tampered.worker_signature = base64url_encode(signature.to_bytes().as_ref());
    assert_eq!(
        harness
            .service
            .record_result(
                &build,
                &worker,
                &claim.lease.claim_token,
                &spki(&key),
                &tampered
            )
            .err(),
        Some("BUILD_RESULT_BINDING_MISMATCH")
    );
    assert_eq!(
        harness
            .service
            .record_result(
                &build,
                &Uuid::new_v4(),
                &claim.lease.claim_token,
                &spki(&key),
                &result
            )
            .err(),
        Some("BUILD_CLAIM_INVALID")
    );
    assert_eq!(
        harness
            .service
            .record_result(
                &build,
                &worker,
                &claim.lease.claim_token,
                &spki(&key),
                &result
            )
            .unwrap()
            .status,
        "completed"
    );
    assert_eq!(
        harness
            .service
            .record_result(
                &build,
                &worker,
                &claim.lease.claim_token,
                &spki(&key),
                &result
            )
            .unwrap()
            .status,
        "completed"
    );
}
