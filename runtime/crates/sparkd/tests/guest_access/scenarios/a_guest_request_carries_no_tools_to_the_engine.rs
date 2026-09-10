#[tokio::test]
async fn a_guest_request_carries_no_tools_to_the_engine() {
    let household = household(&evening_policy());
    let (status, body) = send(
        &household,
        &household.guest,
        Method::POST,
        "/v1/chat/completions",
        json!({
            "model": "qwen3-8b",
            "messages": [{ "role": "user", "content": "hello" }],
            "tools": [{ "type": "function", "function": { "name": "web_search" } }],
            "tool_choice": "auto"
        }),
    )
    .await;
    assert_eq!(status, StatusCode::UNPROCESSABLE_ENTITY);
    assert_eq!(error_code(&body), "GUEST_PARAMETER_NOT_ALLOWED");
}
