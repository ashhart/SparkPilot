use super::tcp_authentication::rfc3339;
use super::*;

fn descriptor(identity: &NodeIdentity) -> ClusterMemberDescriptor {
    ClusterMemberDescriptor {
        node_id: identity.node_id(),
        name: identity.public.node_name.clone(),
        authority_public_key: identity.public.authority_public_key.clone(),
        authority_fingerprint: identity.public.authority_fingerprint.clone(),
        runtime_version: "0.1.0".into(),
        engine_image: format!("vllm@sha256:{}", "a".repeat(64)),
    }
}

#[test]
fn tcp_nonce_exchange_authenticates_both_members_on_one_exact_path() {
    let first = Arc::new(NodeIdentity::generate("first"));
    let second = Arc::new(NodeIdentity::generate("second"));
    let now = OffsetDateTime::now_utc();
    let proposal = Arc::new(ClusterProposal {
        version: 1,
        transaction_id: Uuid::new_v4(),
        cluster_id: Uuid::new_v4(),
        name: "test pair".into(),
        coordinator_node_id: first.node_id(),
        owner_device_id: Uuid::new_v4(),
        expires_at: rfc3339(now + time::Duration::minutes(5)).unwrap(),
        members: vec![descriptor(&first), descriptor(&second)],
    });
    let reserved = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
    let port = reserved.local_addr().unwrap().port();
    drop(reserved);
    let authenticator = TcpClusterPeerAuthenticator {
        port,
        socket_address_override: Some((Ipv4Addr::new(127, 0, 0, 1), Ipv4Addr::new(127, 0, 0, 1))),
    };
    let (first_proof, second_proof) = thread::scope(|scope| {
        let first_authenticator = authenticator.clone();
        let first_proposal = proposal.clone();
        let first_identity = first.clone();
        let first_task = scope
            .spawn(move || first_authenticator.authenticate(&first_proposal, &first_identity, now));
        let second_authenticator = authenticator.clone();
        let second_proposal = proposal.clone();
        let second_identity = second.clone();
        let second_task = scope.spawn(move || {
            second_authenticator.authenticate(&second_proposal, &second_identity, now)
        });
        (
            first_task.join().unwrap().unwrap(),
            second_task.join().unwrap().unwrap(),
        )
    });
    let verify_at = OffsetDateTime::now_utc() + time::Duration::seconds(1);
    first_proof
        .verify(
            &proposal,
            proposal
                .members
                .iter()
                .find(|member| member.node_id == first.node_id())
                .unwrap(),
            verify_at,
        )
        .unwrap();
    second_proof
        .verify(
            &proposal,
            proposal
                .members
                .iter()
                .find(|member| member.node_id == second.node_id())
                .unwrap(),
            verify_at,
        )
        .unwrap();
    assert_eq!(
        first_proof.transcript_canonical(),
        second_proof.transcript_canonical()
    );
}

/// Fresh live proofs finish after request capture and must remain verifiable against their observation time.
#[test]
fn a_proof_observed_after_the_request_began_is_verified_against_its_own_instant() {
    let now = OffsetDateTime::from_unix_timestamp(1_800_000_000).unwrap();
    let format = &time::format_description::well_known::Rfc3339;

    let mut proof = ClusterFabricAuthenticationProof {
        version: PROPOSAL_VERSION,
        transaction_id: Uuid::from_u128(1),
        cluster_id: Uuid::from_u128(2),
        proposal_digest: String::new(),
        member_node_id: Uuid::from_u128(3),
        initiator_node_id: Uuid::from_u128(3),
        responder_node_id: Uuid::from_u128(4),
        initiator_address: Ipv4Addr::new(172, 31, 252, 1),
        responder_address: Ipv4Addr::new(172, 31, 252, 2),
        initiator_authority_public_key: String::new(),
        responder_authority_public_key: String::new(),
        initiator_nonce: String::new(),
        responder_nonce: String::new(),
        initiated_at: now.format(format).unwrap(),
        responded_at: now.format(format).unwrap(),
        initiator_signature: String::new(),
        responder_signature: String::new(),
        acknowledgement_signature: String::new(),
        completion_signature: String::new(),
        observed_at: (now + time::Duration::milliseconds(500))
            .format(format)
            .unwrap(),
        authority_signature: String::new(),
    };

    // Verification time must not precede the fresh proof's observation.
    assert!(proof.verification_instant(now) > now);
    assert_eq!(
        proof.verification_instant(now),
        now + time::Duration::milliseconds(500)
    );

    // Older proofs still use the caller's current time for freshness enforcement.
    proof.observed_at = (now - time::Duration::seconds(10)).format(format).unwrap();
    assert_eq!(proof.verification_instant(now), now);

    // Malformed observation times fall back to caller time and still fail timestamp validation.
    proof.observed_at = "not a timestamp".to_owned();
    assert_eq!(proof.verification_instant(now), now);
}
