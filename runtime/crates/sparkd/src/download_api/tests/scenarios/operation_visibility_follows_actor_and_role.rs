#[test]
fn operation_visibility_follows_actor_and_role() {
    // Restrict reads and cancellation to the operation actor, owner or administrator.
    let actor = uuid::Uuid::new_v4();
    let other = uuid::Uuid::new_v4();
    let op = operation_owned_by(actor);

    // The device that created it can see it.
    assert!(may_view_operation(&principal_with("user", actor), &op));
    // A different non-elevated device cannot.
    assert!(!may_view_operation(
        &principal_with("developer", other),
        &op
    ));
    // Owner and administrator see any operation.
    assert!(may_view_operation(&principal_with("owner", other), &op));
    assert!(may_view_operation(
        &principal_with("administrator", other),
        &op
    ));
    // An unknown role gets the lowest authority and is denied.
    assert!(!may_view_operation(&principal_with("banana", other), &op));
}
