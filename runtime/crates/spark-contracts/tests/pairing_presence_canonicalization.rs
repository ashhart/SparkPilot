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
    challenge: String,
    invitation_id: uuid::Uuid,
    device_id: uuid::Uuid,
    node_id: uuid::Uuid,
    presence_key_fingerprint: String,
}

#[test]
fn shared_fixture_pins_pairing_presence_registration_bytes() {
    let fixture: Fixture = serde_json::from_str(include_str!(
        "../../../../contracts/fixtures/pairing-presence-key-canonicalization.json"
    ))
    .unwrap();

    for case in fixture.cases {
        assert_eq!(
            spark_contracts::pairing_presence_canonical(
                &case.input.challenge,
                &case.input.invitation_id,
                &case.input.device_id,
                &case.input.node_id,
                &case.input.presence_key_fingerprint,
            ),
            case.canonical
        );
    }
}
