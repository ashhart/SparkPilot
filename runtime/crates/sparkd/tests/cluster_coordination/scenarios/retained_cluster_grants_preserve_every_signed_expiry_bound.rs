#[test]
fn retained_cluster_grants_preserve_every_signed_expiry_bound() {
    let (first, second, owner, _, now) = pair();
    let proposal = proposal(&first, &second, owner, now);
    let mut grants = vec![
        first.service.prepare(&proposal, owner, now).unwrap(),
        second.service.prepare(&proposal, owner, now).unwrap(),
    ];
    ready_pair(&first, &second, &proposal, &grants, now);
    grants.sort_by_key(|grant| grant.member_node_id);
    let retained = first.service.retained_grants().unwrap();
    assert_eq!(retained, grants);
}
