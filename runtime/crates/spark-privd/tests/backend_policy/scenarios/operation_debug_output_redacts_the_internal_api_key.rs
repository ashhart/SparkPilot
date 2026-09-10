#[test]
fn operation_debug_output_redacts_the_internal_api_key() {
    let operation = start_operation(Uuid::new_v4());
    let debug = format!("{operation:?}");
    assert!(debug.contains("<redacted>"));
    assert!(!debug.contains(&"b".repeat(64)));
}
