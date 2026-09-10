/// Reject bounded-input violations with the specific failed limit before downstream work.
#[tokio::test]
async fn text_analysis_refuses_input_outside_the_documented_bounds() {
    let (_h, addr, owner, _observer) = harness().await;
    let client = reqwest::Client::new();
    load_model(&client, addr, &owner).await;

    let cases: Vec<(&str, Value)> = vec![
        ("empty text", analysis_body("")),
        (
            "oversize text",
            analysis_body(&"a".repeat(sparkd::analysis::MAX_TEXT_BYTES + 1)),
        ),
        (
            "empty instruction",
            json!({ "instruction": "", "text": "hello" }),
        ),
        (
            "oversize instruction",
            json!({
                "instruction": "a".repeat(sparkd::analysis::MAX_INSTRUCTION_BYTES + 1),
                "text": "hello",
            }),
        ),
        (
            "oversize source name",
            json!({
                "instruction": "Summarise it.",
                "text": "hello",
                "source_name": "a".repeat(sparkd::analysis::MAX_SOURCE_NAME_BYTES + 1),
            }),
        ),
        (
            "output token ceiling",
            json!({
                "instruction": "Summarise it.",
                "text": "hello",
                "max_output_tokens": sparkd::analysis::MAX_OUTPUT_TOKENS + 1,
            }),
        ),
        (
            "zero output tokens",
            json!({ "instruction": "Summarise it.", "text": "hello", "max_output_tokens": 0 }),
        ),
    ];

    for (label, body) in cases {
        let (status, response) =
            post(&client, addr, &owner, "/api/v1/inference/analyses", body).await;
        assert_eq!(status, 422, "{label} must be refused: {response}");
        assert_eq!(
            response["error"]["code"], "ANALYSIS_INPUT_INVALID",
            "{label}: {response}"
        );
    }
}
