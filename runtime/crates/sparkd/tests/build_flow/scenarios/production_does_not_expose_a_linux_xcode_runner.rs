#[test]
fn production_does_not_expose_a_linux_xcode_runner() {
    let source = std::fs::read_to_string("src/main.rs").unwrap();
    assert!(!source.contains("LocalXcodeRunner"));
    assert!(!source.contains("xcodebuild"));
}
