use super::*;
use crate::auth::AccessAuthentication;

fn fixture() -> (Connection, Principal, Principal, Principal) {
    let mut conn = Connection::open_in_memory().unwrap();
    crate::migration::migrate(&mut conn).unwrap();
    let actors = ["owner", "user", "observer"].map(|role| {
        let id = Uuid::new_v4();
        crate::store::insert_device(
            &conn,
            &id,
            role,
            "ios",
            id.as_bytes(),
            &id.to_string(),
            role,
        )
        .unwrap();
        Principal {
            device_id: id,
            role: role.into(),
            access_authentication: AccessAuthentication::DeviceSignature,
            user_presence: None,
        }
    });
    let [owner, first, second] = actors;
    (conn, owner, first, second)
}
fn join(conn: &Connection, owner: &Principal, caller: &Principal) {
    let result = store::set_member(
        conn,
        owner,
        &MemberRequest {
            device_id: caller.device_id,
            joined: true,
        },
        1_800_000_000,
        "2026-09-05T12:00:00Z",
    )
    .unwrap();
    assert!(result.status.is_success());
}
fn note() -> NoteRequest {
    NoteRequest {
        id: Uuid::new_v4(),
        expected_revision: 0,
        title: "Household plan".into(),
        body: "A deliberately shared note".into(),
        delete: false,
    }
}

#[test]
fn pairing_alone_never_grants_household_access_and_removal_is_immediate() {
    let (conn, owner, first, second) = fixture();
    assert!(access(&conn, &owner, 1_800_000_000).is_ok());
    assert!(access(&conn, &first, 1_800_000_000).is_err());
    join(&conn, &owner, &first);
    assert!(access(&conn, &first, 1_800_000_000).is_ok());
    assert!(access(&conn, &second, 1_800_000_000).is_err());
    store::set_member(
        &conn,
        &owner,
        &MemberRequest {
            device_id: first.device_id,
            joined: false,
        },
        1_800_000_000,
        "2026-09-05T12:00:00Z",
    )
    .unwrap();
    assert!(access(&conn, &first, 1_800_000_000).is_err());
}

#[test]
fn attribution_and_compare_and_swap_prevent_overwriting_another_person_or_a_newer_note() {
    let (conn, owner, first, second) = fixture();
    join(&conn, &owner, &first);
    join(&conn, &owner, &second);
    let first_member = access(&conn, &first, 1_800_000_000).unwrap();
    let second_member = access(&conn, &second, 1_800_000_000).unwrap();
    let mut request = note();
    assert!(
        store::save_note(
            &conn,
            &first,
            &first_member,
            &request,
            "2026-09-05T12:00:00Z"
        )
        .unwrap()
        .status
        .is_success()
    );
    assert_eq!(
        store::save_note(
            &conn,
            &first,
            &first_member,
            &request,
            "2026-09-05T12:01:00Z"
        )
        .unwrap()
        .status,
        StatusCode::CONFLICT
    );
    request.expected_revision = 1;
    request.body = "New text".into();
    assert_eq!(
        store::save_note(
            &conn,
            &second,
            &second_member,
            &request,
            "2026-09-05T12:01:00Z"
        )
        .unwrap()
        .status,
        StatusCode::FORBIDDEN
    );
    assert!(
        store::save_note(
            &conn,
            &first,
            &first_member,
            &request,
            "2026-09-05T12:01:00Z"
        )
        .unwrap()
        .status
        .is_success()
    );
    let notes = store::notes(&conn, second.device_id, false).unwrap();
    assert_eq!(notes[0]["body"], "New text");
    assert_eq!(notes[0]["author_name"], "user");
    assert_eq!(notes[0]["revision"], 2);
    assert_eq!(notes[0]["can_edit"], false);
}

#[test]
fn deleting_a_note_purges_its_text_and_a_stale_edit_cannot_restore_it() {
    let (conn, owner, _, _) = fixture();
    let member = access(&conn, &owner, 1_800_000_000).unwrap();
    let mut request = note();
    store::save_note(&conn, &owner, &member, &request, "2026-09-05T12:00:00Z").unwrap();
    request.expected_revision = 1;
    request.delete = true;
    let response =
        store::save_note(&conn, &owner, &member, &request, "2026-09-05T12:01:00Z").unwrap();
    assert!(response.status.is_success());
    assert!(!response.body.to_string().contains(&request.body));
    assert!(
        store::notes(&conn, owner.device_id, true)
            .unwrap()
            .is_empty()
    );
    let body: String = conn
        .query_row(
            "SELECT body FROM household_notes WHERE id=?1",
            [request.id.to_string()],
            |row| row.get(0),
        )
        .unwrap();
    assert!(body.is_empty());
    request.delete = false;
    request.expected_revision = 2;
    assert_eq!(
        store::save_note(&conn, &owner, &member, &request, "2026-09-05T12:02:00Z")
            .unwrap()
            .status,
        StatusCode::CONFLICT
    );
}

#[test]
fn a_revoked_device_cannot_reuse_membership_and_limits_are_checked_before_inserting() {
    let (conn, owner, first, _) = fixture();
    join(&conn, &owner, &first);
    conn.execute(
        "UPDATE devices SET revoked_at='2026-09-05T12:00:00Z' WHERE id=?1",
        [first.device_id.to_string()],
    )
    .unwrap();
    assert!(access(&conn, &first, 1_800_000_000).is_err());
    let mut request = note();
    request.body = "x".repeat(16385);
    let member = access(&conn, &owner, 1_800_000_000).unwrap();
    assert_eq!(
        store::save_note(&conn, &owner, &member, &request, "2026-09-05T12:00:00Z")
            .unwrap()
            .status,
        StatusCode::UNPROCESSABLE_ENTITY
    );
    assert!(
        store::notes(&conn, owner.device_id, true)
            .unwrap()
            .is_empty()
    );
}
