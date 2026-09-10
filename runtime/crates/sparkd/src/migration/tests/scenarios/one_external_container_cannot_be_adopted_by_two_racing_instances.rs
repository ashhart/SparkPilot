#[test]
fn one_external_container_cannot_be_adopted_by_two_racing_instances() {
    let mut conn = mem();
    migrate(&mut conn).expect("migrate");
    conn.execute(
        "INSERT INTO models (id, recipe_revision, recipe_digest, source_revision, display_name, install_state) VALUES ('example/model', 'r1', 'sha256:aa', 's1', 'Example', 'installed')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO model_profiles (model_id, profile_id, context_length, max_sequences, max_batched_tokens, gpu_memory_utilisation) VALUES ('example/model', 'balanced', 16384, 4, 8192, 0.7)",
        [],
    )
    .unwrap();
    let container = "a".repeat(64);
    conn.execute(
        "INSERT INTO inference_instances (id, model_id, profile_id, node_id, state, container_id) VALUES (?1, 'example/model', 'balanced', 'node', 'ready', ?2)",
        rusqlite::params![uuid::Uuid::new_v4().to_string(), container],
    )
    .unwrap();
    let second = conn.execute(
        "INSERT INTO inference_instances (id, model_id, profile_id, node_id, state, container_id) VALUES (?1, 'example/model', 'balanced', 'node', 'ready', ?2)",
        rusqlite::params![uuid::Uuid::new_v4().to_string(), "a".repeat(64)],
    );
    assert!(
        second.is_err(),
        "the ownership transition must be unique by container id"
    );
}
