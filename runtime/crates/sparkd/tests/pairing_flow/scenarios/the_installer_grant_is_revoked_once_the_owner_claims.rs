/// Retire the temporary installer administrator after its first-owner invitation is claimed.
#[tokio::test]
async fn the_installer_grant_is_revoked_once_the_owner_claims() {
    let peer = full_peer();
    let (invitation, installer_id) = bootstrap_owner_invitation(&peer);

    let active_before: i64 = {
        let conn = peer.state.database.as_ref().expect("db").lock();
        conn.query_row(
            "SELECT COUNT(*) FROM devices WHERE id = ?1 AND revoked_at IS NULL",
            rusqlite::params![installer_id.to_string()],
            |row| row.get::<_, i64>(0),
        )
        .expect("installer grant present")
    };
    assert_eq!(active_before, 1, "the installer grant starts active");

    let owner = full_peer();
    let (status, _) = run_claim(&peer, &invitation, &owner, "Owner iPhone", "ios").await;
    assert_eq!(status, StatusCode::CREATED);

    let conn = peer.state.database.as_ref().expect("db").lock();
    let revoked_at: Option<String> = conn
        .query_row(
            "SELECT revoked_at FROM devices WHERE id = ?1",
            rusqlite::params![installer_id.to_string()],
            |row| row.get::<_, Option<String>>(0),
        )
        .expect("installer grant still recorded");
    assert!(
        revoked_at.is_some(),
        "the installer grant must be revoked by the owner claim"
    );

    // Revoked, not deleted: audit attribution for the install survives.
    let display_name: String = conn
        .query_row(
            "SELECT display_name FROM devices WHERE id = ?1",
            rusqlite::params![installer_id.to_string()],
            |row| row.get::<_, String>(0),
        )
        .expect("row survives");
    assert_eq!(display_name, sparkd::store::INSTALLER_DEVICE_NAME);

    // Exactly one active administrator-or-owner device remains: the owner.
    let active_admins: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM devices \
             WHERE revoked_at IS NULL AND role IN ('owner', 'administrator')",
            [],
            |row| row.get::<_, i64>(0),
        )
        .expect("count");
    assert_eq!(active_admins, 1);
}
