use serde::Deserialize;

#[derive(Debug, Deserialize)]
struct Fixture {
    cases: Vec<Case>,
}

#[derive(Debug, Deserialize)]
struct Case {
    input: Input,
    canonical: String,
}

#[derive(Debug, Deserialize)]
struct Input {
    method: String,
    path_and_query: String,
    timestamp: String,
    nonce: String,
    content_sha256: String,
    device_id: uuid::Uuid,
    node_id: uuid::Uuid,
    expires_at: String,
}

#[test]
fn shared_fixture_pins_presence_proof_bytes() {
    let fixture: Fixture = serde_json::from_str(include_str!(
        "../../../../contracts/fixtures/user-presence-canonicalization.json"
    ))
    .unwrap();

    for case in fixture.cases {
        assert_eq!(
            spark_contracts::user_presence_canonical(
                &case.input.method,
                &case.input.path_and_query,
                &case.input.timestamp,
                &case.input.nonce,
                &case.input.content_sha256,
                &case.input.device_id,
                &case.input.expires_at,
                &case.input.node_id,
            ),
            case.canonical
        );
    }
}

#[test]
fn generated_contract_requires_proof_only_for_revocation() {
    let missing_presence = serde_json::json!({
        "deviceId": uuid::Uuid::new_v4(),
        "Idempotency-Key": uuid::Uuid::new_v4(),
    });
    assert!(
        serde_json::from_value::<spark_contracts::generated::RevokeDeviceParameters>(
            missing_presence
        )
        .is_err()
    );

    let legacy_claim = serde_json::json!({
        "invitation": {
            "version": 1,
            "node_id": uuid::Uuid::new_v4(),
            "authority_fingerprint": "authority",
            "invitation_id": uuid::Uuid::new_v4(),
            "nonce": "nonce",
            "role": "owner",
            "expires_at": "2026-08-28T14:30:00Z",
            "signature": "signature"
        },
        "challenge_id": uuid::Uuid::new_v4(),
        "device_id": uuid::Uuid::new_v4(),
        "device_name": "Legacy iPhone",
        "platform": "ios",
        "device_public_key_spki": "spki",
        "challenge_signature": "signature"
    });
    let decoded =
        serde_json::from_value::<spark_contracts::generated::PairingClaim>(legacy_claim).unwrap();
    assert_eq!(decoded.presence_public_key_spki, None);
}
