/// Exercise 50,000 typed-body cases without panics and bound parser-error growth; public refusals must omit input text.
#[test]
fn the_typed_bodies_reject_the_corpus_without_panicking() {
    let keys = [
        "model_id",
        "profile_id",
        "replace_active",
        "target",
        "accepted_preview_digest",
        "node_id",
        "cluster_id",
        "force",
        "trust_remote_code",
        "image",
        "command",
    ];
    let mut accepted = 0usize;
    for case in body_corpus(
        PARSE_SEED,
        PARSE_CASES,
        &keys,
        r#"{"model_id":"example/model-32b","profile_id":"balanced-32k","replace_active":false}"#,
    ) {
        // Allow only linear internal serde error growth; typed_refusals replaces raw text with fixed public errors.
        let bounded = |error: serde_json::Error, what: &str| {
            let message = error.to_string();
            assert!(
                message.len() <= 512 + case.bytes.len(),
                "{what} turned {} input bytes into a {} byte error for {}",
                case.bytes.len(),
                message.len(),
                case.label
            );
        };
        match serde_json::from_slice::<sparkd::engine_api::LoadModelBody>(&case.bytes) {
            Ok(body) => {
                accepted += 1;
                // Accepted values remain typed schema fields for subsequent handler validation, not arbitrary configuration.
                let _ = (body.model_id, body.profile_id);
            }
            Err(error) => bounded(error, "LoadModelBody"),
        }
        if let Err(error) = serde_json::from_slice::<sparkd::engine_api::StopModelBody>(&case.bytes)
        {
            bounded(error, "StopModelBody");
        }
        if let Err(error) =
            serde_json::from_slice::<sparkd::engine_api::LoadModelPreviewBody>(&case.bytes)
        {
            bounded(error, "LoadModelPreviewBody");
        }
    }
    // Require accepted cases too so the generator tests both success and refusal paths.
    assert!(
        accepted > 0,
        "no generated body ever parsed; the corpus has stopped resembling the schema"
    );
}
