/// An unverified import colliding with an installed id must not change its recipe or installed state (H5).
#[tokio::test]
async fn unverified_import_cannot_break_an_installed_model_by_id_collision() {
    let peer = full_peer(true);
    // Use an installed repository/40-hex-revision id that exactly matches the import-generated identity.
    let installed_id = "example/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    {
        let conn = peer.state.database.as_ref().unwrap().lock();
        conn.execute(
            "INSERT INTO models
                (id, recipe_revision, recipe_digest, source_revision,
                 display_name, install_state)
             VALUES (?1, '1', 'd', ?2, 'Installed model', 'installed')",
            rusqlite::params![installed_id, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"],
        )
        .unwrap();
    }

    // repository/revision concatenates to exactly the installed model's id.
    let (status, body) = send(
        &peer,
        Method::POST,
        "/api/v1/models/import",
        json!({ "repository": "example", "revision": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" }),
    )
    .await;
    assert_eq!(status, StatusCode::CONFLICT);
    assert_eq!(body.unwrap()["error"]["code"], "MODEL_ALREADY_INSTALLED");

    let conn = peer.state.database.as_ref().unwrap().lock();
    let state: String = conn
        .query_row(
            "SELECT install_state FROM models WHERE id = ?1",
            [installed_id],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(
        state, "installed",
        "the installed model must survive the import"
    );
}
