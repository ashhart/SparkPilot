#[test]
fn prepare_is_idempotent_and_transaction_ids_cannot_be_rebound() {
    let (first, second, owner, _, now) = pair();
    let original = proposal(&first, &second, owner, now);
    let first_grant = first.service.prepare(&original, owner, now).unwrap();
    let replay = first.service.prepare(&original, owner, now).unwrap();
    assert_eq!(first_grant, replay);
    assert_eq!(first.link.phases.lock().unwrap().len(), 1);

    let mut changed = original.clone();
    changed.name = "Another cluster".into();
    assert!(matches!(
        first.service.prepare(&changed, owner, now),
        Err(CoordinationError::Conflict(_))
    ));
}
