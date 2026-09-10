#[test]
fn interrupted_create_without_receipt_preserves_objects_and_refuses_adoption() {
    let fixture = Fixture::new();
    fixture.install();
    fixture.docker.state.lock().unwrap().lose_create_receipt = true;
    assert!(
        fixture
            .backend
            .execute(&PrivilegedOperation::UpdateOpenWebUi {
                request_id: uuid::Uuid::new_v4(),
                image_digest: image('c')
            })
            .is_err()
    );
    let count = fixture.docker.state.lock().unwrap().containers.len();
    assert_eq!(count, 2);
    assert_eq!(fixture.repair().code, "OPEN_WEBUI_OWNERSHIP_UNVERIFIED");
    assert_eq!(fixture.remove(true).code, "OPEN_WEBUI_OWNERSHIP_UNVERIFIED");
    assert_eq!(fixture.docker.state.lock().unwrap().containers.len(), count);
}
