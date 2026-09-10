use serde::Deserialize;

#[derive(Deserialize)]
struct Fixture {
    cases: Vec<Case>,
}

#[derive(Deserialize)]
struct Case {
    input: Input,
    canonical: String,
}

#[derive(Deserialize)]
struct Input {
    method: String,
    path_and_query: String,
    timestamp: String,
    nonce: String,
    content_sha256: String,
    device_id: uuid::Uuid,
    node_id: uuid::Uuid,
    presence_key_fingerprint: String,
}

#[test]
fn enrollment_canonicalization_matches_shared_fixture() {
    let fixture: Fixture = serde_json::from_str(include_str!(
        "../../../../contracts/fixtures/presence-key-enrollment-canonicalization.json"
    ))
    .unwrap();

    for case in fixture.cases {
        assert_eq!(
            spark_contracts::presence_enrollment_canonical(
                &case.input.method,
                &case.input.path_and_query,
                &case.input.timestamp,
                &case.input.nonce,
                &case.input.content_sha256,
                &case.input.device_id,
                &case.input.presence_key_fingerprint,
                &case.input.node_id,
            ),
            case.canonical
        );
    }
}
