/// Refusals must not echo body text, amplify attacker input or contaminate logs.
#[tokio::test]
async fn a_refusal_never_echoes_the_body_back() {
    let harness = harness();
    let needle = "q".repeat(4096);
    let mut probes: Vec<(&str, &str, String)> = Vec::new();
    for (method, path, keys, _) in body_routes() {
        let key = keys[0];
        probes.push((method, path, format!("{{\"{needle}\":1}}")));
        probes.push((method, path, format!("{{\"{key}\":\"{needle}\"}}")));
        probes.push((method, path, format!("[\"{needle}\"]")));
    }
    // Probe inference extractor errors without an engine because malformed-body refusal precedes handler execution.
    probes.push((
        "POST",
        "/api/v1/inference/load",
        format!("{{\"model_id\":\"{needle}\",\"profile_id\":\"p\",\"{needle}\":1}}"),
    ));
    for (method, path, body) in probes {
        let (status, response) = send(
            harness.state.clone(),
            signed(&harness, method, path, body.as_bytes()),
        )
        .await;
        assert!(
            status.is_client_error(),
            "{method} {path} answered {status}"
        );
        let text = String::from_utf8_lossy(&response).into_owned();
        assert!(
            !text.contains(&needle[..64]),
            "the refusal echoed the body: {}",
            &text[..text.len().min(200)]
        );
        assert!(
            response.len() < 1024,
            "a {} byte body produced a {} byte refusal",
            body.len(),
            response.len()
        );
    }
}
