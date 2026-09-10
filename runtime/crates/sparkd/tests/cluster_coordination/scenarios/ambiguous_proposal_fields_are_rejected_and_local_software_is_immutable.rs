#[test]
fn ambiguous_proposal_fields_are_rejected_and_local_software_is_immutable() {
    let (first, second, owner, _, now) = pair();
    let base = proposal(&first, &second, owner, now);
    let mut first_shape = base.clone();
    first_shape.members[0].runtime_version = "x\ny".into();
    first_shape.members[0].engine_image = "z".into();
    let mut second_shape = base.clone();
    second_shape.members[0].runtime_version = "x".into();
    second_shape.members[0].engine_image = "y\nz".into();
    assert!(first_shape.digest().is_err());
    assert!(second_shape.digest().is_err());
    assert!(matches!(
        first.service.prepare(&first_shape, owner, now),
        Err(CoordinationError::InvalidProposal(_))
    ));

    let mut substituted = base;
    substituted.members[0].engine_image =
        "vllm@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb".into();
    assert!(matches!(
        first.service.prepare(&substituted, owner, now),
        Err(CoordinationError::InvalidProposal(_))
    ));
    assert!(first.link.phases.lock().unwrap().is_empty());
}
