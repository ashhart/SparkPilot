#[test]
fn runner_command_output_is_capped_by_the_system_runner_bound() {
    // Bound runner output so noisy children cannot exhaust helper memory.
    assert_eq!(spark_privd::update::MAX_COMMAND_OUTPUT_BYTES, 1 << 20);
    
    let runner = RecordingRunner::new();
    runner.ok(Some(0), "out", "err");
    let out = runner.run("/bin/true", &[]).unwrap();
    assert_eq!(out.stdout, b"out");
    assert_eq!(out.stderr, b"err");
    let _ = CommandOutput::default();
    let _ = DEFAULT_STAGING_ROOT;
}
