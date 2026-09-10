use super::*;
use std::sync::Arc;

use crate::cluster::{PeerFacts, record_peer_facts};
use parking_lot::Mutex;

fn database() -> Arc<Mutex<Connection>> {
    let mut connection = Connection::open_in_memory().unwrap();
    crate::migration::migrate(&mut connection).unwrap();
    Arc::new(Mutex::new(connection))
}

fn node(index: u128) -> String {
    uuid::Uuid::from_u128(index).to_string()
}

fn record_member(database: &Arc<Mutex<Connection>>, index: u128) {
    record_peer_facts(
        &database.lock(),
        &PeerFacts {
            node_id: node(index),
            name: format!("Spark {index}"),
            authority_fingerprint: "shared-authority".into(),
            runtime_version: "0.1.0".into(),
            engine_image: "external".into(),
        },
        "pinned_tls_identity",
    )
    .unwrap();
}

fn record_reciprocal_link(database: &Arc<Mutex<Connection>>, left: u128, right: u128) {
    let expires_at = "2099-01-01T00:00:00Z";
    for (observer, peer, port) in [(left, right, "left"), (right, left, "right")] {
        record_fabric_peer_proof(
            &database.lock(),
            &FabricPeerProof {
                observer_node_id: node(observer),
                observer_port_id: port.into(),
                peer_node_id: node(peer),
                peer_port_id: None,
                verified_at: "2026-08-31T00:00:00Z".into(),
                expires_at: expires_at.into(),
                source: FabricProofSource::MutualTlsChallenge,
            },
        )
        .unwrap();
    }
}

#[test]
fn external_import_preview_supports_variable_membership_without_mutating_cluster_state() {
    let database = database();
    for index in 1..=4 {
        record_member(&database, index);
    }
    record_reciprocal_link(&database, 1, 2);
    record_reciprocal_link(&database, 2, 3);
    record_reciprocal_link(&database, 3, 4);

    let before: i64 = database
        .lock()
        .query_row("SELECT COUNT(*) FROM cluster_state", [], |row| row.get(0))
        .unwrap();
    let preview = preview_external_import(
        &database.lock(),
        "Lab cluster",
        &[node(1), node(2), node(3), node(4)],
        "2026-08-31T12:00:00Z",
    )
    .unwrap();
    let after: i64 = database
        .lock()
        .query_row("SELECT COUNT(*) FROM cluster_state", [], |row| row.get(0))
        .unwrap();

    assert_eq!(before, 0);
    assert_eq!(after, 0, "a preview must not register cluster identity");
    assert_eq!(preview.configuration_owner, EXTERNALLY_CONFIGURED);
    assert_eq!(preview.members.len(), 4);
    assert_eq!(preview.authenticated_links.len(), 3);
    assert!(preview.evidence_complete);
    assert!(!preview.registration_available);
    assert!(!preview.automatic_topology_available);
    assert!(!preview.takeover_available);
    assert!(preview.blockers.is_empty());
}

#[test]
fn carrier_or_one_way_peer_claim_never_authenticates_a_fabric_link() {
    let database = database();
    record_member(&database, 1);
    record_member(&database, 2);
    record_fabric_peer_proof(
        &database.lock(),
        &FabricPeerProof {
            observer_node_id: node(1),
            observer_port_id: "left".into(),
            peer_node_id: node(2),
            peer_port_id: None,
            verified_at: "2026-08-31T00:00:00Z".into(),
            expires_at: "2099-01-01T00:00:00Z".into(),
            source: FabricProofSource::MutualTlsChallenge,
        },
    )
    .unwrap();

    let preview = preview_external_import(
        &database.lock(),
        "Unproven cluster",
        &[node(1), node(2)],
        "2026-08-31T12:00:00Z",
    )
    .unwrap();

    assert!(preview.authenticated_links.is_empty());
    assert!(!preview.evidence_complete);
    assert!(
        preview
            .blockers
            .iter()
            .any(|blocker| blocker.code == "FABRIC_PEER_NOT_RECIPROCAL")
    );
}

#[test]
fn selected_member_without_trusted_identity_stays_unverified() {
    let database = database();
    record_member(&database, 1);

    let preview = preview_external_import(
        &database.lock(),
        "Candidate",
        &[node(1), node(2)],
        "2026-08-31T12:00:00Z",
    )
    .unwrap();

    assert!(!preview.evidence_complete);
    assert_eq!(preview.members.len(), 2);
    assert!(preview.members[0].identity_authenticated);
    assert!(!preview.members[1].identity_authenticated);
    assert!(
        preview
            .blockers
            .iter()
            .any(|blocker| blocker.code == "MEMBER_IDENTITY_UNVERIFIED")
    );
}

#[test]
fn independently_authenticated_members_with_different_authorities_are_blocked() {
    let database = database();
    record_member(&database, 1);
    record_peer_facts(
        &database.lock(),
        &PeerFacts {
            node_id: node(2),
            name: "Foreign Spark".into(),
            authority_fingerprint: "foreign-authority".into(),
            runtime_version: "0.1.0".into(),
            engine_image: "external".into(),
        },
        "pinned_tls_identity",
    )
    .unwrap();
    record_reciprocal_link(&database, 1, 2);

    let preview = preview_external_import(
        &database.lock(),
        "Mixed authority",
        &[node(1), node(2)],
        "2026-08-31T12:00:00Z",
    )
    .unwrap();

    assert!(!preview.evidence_complete);
    assert!(preview.blockers.iter().any(|blocker| {
        blocker.code == "MEMBER_AUTHORITY_MISMATCH"
            && blocker.member_node_id.as_deref() == Some(node(2).as_str())
    }));
}

#[test]
fn fabric_proof_cannot_be_recorded_for_an_unverified_identity() {
    let database = database();
    record_member(&database, 1);
    let error = record_fabric_peer_proof(
        &database.lock(),
        &FabricPeerProof {
            observer_node_id: node(1),
            observer_port_id: "left".into(),
            peer_node_id: node(2),
            peer_port_id: None,
            verified_at: "2026-08-31T00:00:00Z".into(),
            expires_at: "2099-01-01T00:00:00Z".into(),
            source: FabricProofSource::MutualTlsChallenge,
        },
    )
    .unwrap_err();
    assert!(matches!(error, ClusterError::UnknownPeer(_)));
}
