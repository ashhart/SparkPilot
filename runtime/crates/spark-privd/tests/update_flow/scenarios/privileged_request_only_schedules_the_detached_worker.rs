#[test]
fn privileged_request_only_schedules_the_detached_worker() {
    let h = Harness::new();
    let argv = h.director().planned_argv("lab-0.1.0").unwrap();
    assert_eq!(argv.len(), 1, "the request handler must only schedule");
    let (program, args) = &argv[0];
    assert_eq!(program, "/usr/bin/systemctl");
    assert_eq!(
        args.iter().map(String::as_str).collect::<Vec<_>>(),
        [
            "--no-block",
            "start",
            "spark-runtime-update@lab-0.1.0.service",
        ]
    );
    let rendered = format!("{argv:?}");
    assert!(!rendered.contains("verify-package"));
    assert!(!rendered.contains("dpkg"));
}
