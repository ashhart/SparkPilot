#[test]
fn legacy_builds_are_closed_and_artifacts_are_bound_during_0019() {
    let mut conn = mem();
    for migration in MIGRATIONS
        .iter()
        .take_while(|entry| entry.version != "0019")
    {
        conn.execute_batch(migration.ddl).unwrap();
        conn.execute(
            "INSERT OR IGNORE INTO schema_migrations (version, applied_at)
             VALUES (?1, '2026-08-31T00:00:00Z')",
            rusqlite::params![migration.version.parse::<i64>().unwrap()],
        )
        .unwrap();
    }
    let device = uuid::Uuid::new_v4().to_string();
    let project = uuid::Uuid::new_v4().to_string();
    let worker = uuid::Uuid::new_v4().to_string();
    let operation = uuid::Uuid::new_v4().to_string();
    let build = uuid::Uuid::new_v4().to_string();
    conn.execute(
        "INSERT INTO devices
         (id, display_name, platform, public_key_spki, public_key_fingerprint, role, paired_at)
         VALUES (?1, 'Owner', 'macos', X'01', ?2, 'owner', '2026-08-31T00:00:00Z')",
        rusqlite::params![device, format!("fingerprint-{device}")],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO projects
         (id, name, owner_device_id, root_path, state, created_at, updated_at)
         VALUES (?1, 'Legacy', ?2, ?3, 'ready', '2026-08-31T00:00:00Z', '2026-08-31T00:00:00Z')",
        rusqlite::params![project, device, format!("/legacy/{project}")],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO build_workers
         (id, display_name, device_id, platform_version, xcode_version, capabilities_json,
          state, registered_at)
         VALUES (?1, 'Legacy Mac', ?2, 'macOS 26', '17.0', '{}', 'busy', '2026-08-31T00:00:00Z')",
        rusqlite::params![worker, device],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO operations
         (id, kind, state, actor_device_id, progress, stage, created_at, updated_at, cancellable)
         VALUES (?1, 'build.submit', 'queued', ?2, 0, 'pending',
                 '2026-08-31T00:00:00Z', '2026-08-31T00:00:00Z', 1)",
        rusqlite::params![operation, device],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO builds
         (id, project_id, operation_id, worker_id, commit_sha, scheme, configuration,
          destination, actions_json, timeout_seconds, status, requested_by_device_id,
          created_at, updated_at)
         VALUES (?1, ?2, ?3, ?4, ?5, 'App', 'Debug', 'platform=macOS', '[\"build\"]',
                 600, 'queued', ?6, '2026-08-31T00:00:00Z', '2026-08-31T00:00:00Z')",
        rusqlite::params![build, project, operation, worker, "a".repeat(40), device],
    )
    .unwrap();
    let artifact = uuid::Uuid::new_v4().to_string();
    conn.execute(
        "INSERT INTO build_artifacts
         (id, operation_id, project_id, worker_id, kind, relative_path, sha256,
          size_bytes, created_at)
         VALUES (?1, ?2, ?3, ?4, 'xcresult', 'old.xcresult', ?5, 1,
                 '2026-08-31T00:00:00Z')",
        rusqlite::params![artifact, operation, project, worker, "b".repeat(64)],
    )
    .unwrap();

    assert_eq!(
        migrate(&mut conn).unwrap(),
        MIGRATIONS
            .iter()
            .filter(|entry| entry.version >= "0019")
            .map(|entry| entry.version)
            .collect::<Vec<_>>()
    );
    let build_state: (String, String) = conn
        .query_row(
            "SELECT status, result_json FROM builds WHERE id = ?1",
            [&build],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .unwrap();
    assert_eq!(build_state.0, "failed");
    assert!(build_state.1.contains("BUILD_RECIPE_REQUIRES_RESUBMISSION"));
    let operation_state: (String, f64, String) = conn
        .query_row(
            "SELECT state, progress, error_code FROM operations WHERE id = ?1",
            [&operation],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )
        .unwrap();
    assert_eq!(
        operation_state,
        (
            "failed".into(),
            1.0,
            "BUILD_RECIPE_REQUIRES_RESUBMISSION".into()
        )
    );
    let artifact_binding: (String, i64) = conn
        .query_row(
            "SELECT build_id, claim_generation FROM build_artifacts WHERE id = ?1",
            [&artifact],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .unwrap();
    assert_eq!(artifact_binding, (build, 0));
}
