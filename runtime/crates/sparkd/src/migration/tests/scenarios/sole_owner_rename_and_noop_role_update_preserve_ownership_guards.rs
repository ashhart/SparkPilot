#[test]
fn sole_owner_rename_and_noop_role_update_preserve_ownership_guards() {
    let mut conn = mem();
    migrate(&mut conn).unwrap();
    let id = uuid::Uuid::new_v4();
    crate::store::insert_device(&conn, &id, "Owner", "macos", &[1], "owner-fp", "owner").unwrap();
    crate::store::update_device(&conn, &id, Some("Renamed owner"), None).unwrap();
    crate::store::update_device(&conn, &id, None, Some("owner")).unwrap();
    assert_eq!(
        crate::store::device_row(&conn, &id)
            .unwrap()
            .unwrap()
            .display_name,
        "Renamed owner"
    );
    assert!(crate::store::update_device(&conn, &id, None, Some("observer")).is_err());
    assert!(crate::store::revoke_device(&conn, &id).is_err());
    assert!(
        conn.execute("DELETE FROM devices WHERE id = ?1", [id.to_string()])
            .is_err()
    );
    assert_eq!(crate::store::active_owner_count(&conn).unwrap(), 1);
}
