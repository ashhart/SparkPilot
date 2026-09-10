use std::collections::HashMap;
use std::sync::{Arc, Mutex as StdMutex};

use p256::pkcs8::EncodePublicKey;
use parking_lot::Mutex;
use rusqlite::Connection;
use spark_core::identity::NodeIdentity;
use spark_privd::protocol::ClusterLinkPhase;
use sparkd::cluster_coordination::{
    ClusterCollectiveControl, ClusterCollectiveProof, ClusterCoordinationService,
    ClusterFabricAuthenticationProof, ClusterLinkControl, ClusterLinkProof,
    ClusterMemberDescriptor, ClusterMonitorOutcome, ClusterPeerAuthenticator, ClusterPeerLoss,
    ClusterProposal, CoordinationError, DistributedExecutionSpec, DistributedRuntimeControl,
};
use sparkd::events::EventBus;
use time::OffsetDateTime;
use uuid::Uuid;

#[derive(Default)]
struct RecordingLink {
    phases: StdMutex<Vec<(Uuid, ClusterLinkPhase)>>,
    fail_on: StdMutex<Option<ClusterLinkPhase>>,
    proof_calls: StdMutex<usize>,
    neighbour_override: StdMutex<Option<String>>,
    fail_proof: StdMutex<bool>,
    fail_all_phases: StdMutex<bool>,
}

impl ClusterLinkControl for RecordingLink {
    fn apply(
        &self,
        proposal: &ClusterProposal,
        local_node_id: Uuid,
        phase: ClusterLinkPhase,
    ) -> Result<(), CoordinationError> {
        self.phases.lock().unwrap().push((local_node_id, phase));
        if *self.fail_all_phases.lock().unwrap() {
            return Err(CoordinationError::Link("scripted cleanup failure".into()));
        }
        if *self.fail_on.lock().unwrap() == Some(phase) {
            return Err(CoordinationError::Link("scripted failure".into()));
        }
        proposal.addresses_for(local_node_id)?;
        Ok(())
    }

    fn prove(
        &self,
        proposal: &ClusterProposal,
        local_node_id: Uuid,
    ) -> Result<ClusterLinkProof, CoordinationError> {
        *self.proof_calls.lock().unwrap() += 1;
        if *self.fail_proof.lock().unwrap() {
            return Err(CoordinationError::Link("scripted peer loss".into()));
        }
        let peer_node_id = proposal
            .members
            .iter()
            .find(|member| member.node_id != local_node_id)
            .unwrap()
            .node_id;
        let (local_address, peer_address) = proposal.addresses_for(local_node_id)?;
        Ok(ClusterLinkProof {
            version: 1,
            transaction_id: proposal.transaction_id,
            cluster_id: proposal.cluster_id,
            proposal_digest: proposal.digest()?,
            member_node_id: local_node_id,
            peer_node_id,
            local_address,
            peer_address,
            interface: "fake-cx7".into(),
            local_mac: mac_for(local_node_id),
            neighbour_mac: self
                .neighbour_override
                .lock()
                .unwrap()
                .clone()
                .unwrap_or_else(|| mac_for(peer_node_id)),
            speed_mbps: 200_000,
            mtu: 9_000,
            observed_at: String::new(),
            authority_signature: String::new(),
        })
    }
}

fn mac_for(node_id: Uuid) -> String {
    let bytes = node_id.as_bytes();
    format!(
        "02:{:02x}:{:02x}:{:02x}:{:02x}:{:02x}",
        bytes[0], bytes[1], bytes[2], bytes[3], bytes[4]
    )
}

#[derive(Default)]
struct RecordingCollective {
    calls: StdMutex<usize>,
    latency_us: StdMutex<Option<u64>>,
    bandwidth_mbps: StdMutex<Option<u64>>,
    elapsed_ms: StdMutex<Option<u64>>,
}

struct RecordingPeerAuthenticator {
    identities: HashMap<Uuid, NodeIdentity>,
}

fn test_signature(identity: &NodeIdentity, canonical: &str) -> String {
    use ed25519_dalek::Signer as _;
    sparkd::crypto::base64url_encode(&identity.signing_key().sign(canonical.as_bytes()).to_bytes())
}

impl ClusterPeerAuthenticator for RecordingPeerAuthenticator {
    fn authenticate(
        &self,
        proposal: &ClusterProposal,
        identity: &NodeIdentity,
        now: OffsetDateTime,
    ) -> Result<ClusterFabricAuthenticationProof, CoordinationError> {
        let mut members = proposal.members.iter().collect::<Vec<_>>();
        members.sort_by_key(|member| member.node_id);
        let responder = members[0];
        let initiator = members[1];
        let initiator_identity = &self.identities[&initiator.node_id];
        let responder_identity = &self.identities[&responder.node_id];
        let (initiator_address, responder_address) = proposal.addresses_for(initiator.node_id)?;
        // Use increasing request, response and observation timestamps so proof verification tests the real exchange ordering.
        let format = &time::format_description::well_known::Rfc3339;
        let timestamp = now.format(format).unwrap();
        let responded_timestamp = (now + time::Duration::milliseconds(250))
            .format(format)
            .unwrap();
        let observed_timestamp = (now + time::Duration::milliseconds(500))
            .format(format)
            .unwrap();
        let initiator_nonce = sparkd::crypto::base64url_encode(&[1_u8; 32]);
        let responder_nonce = sparkd::crypto::base64url_encode(&[2_u8; 32]);
        let hello = format!(
            "SPARK-CLUSTER-FABRIC-HELLO1\n{}\n{}\n{}\n{}\n{}\n{}\n{}\n{}\n{}\n{}\n{}",
            proposal.transaction_id,
            proposal.cluster_id,
            proposal.digest()?,
            initiator.node_id,
            responder.node_id,
            initiator_address,
            responder_address,
            initiator.authority_public_key,
            responder.authority_public_key,
            initiator_nonce,
            timestamp,
        );
        let initiator_signature = test_signature(initiator_identity, &hello);
        let response = format!(
            "SPARK-CLUSTER-FABRIC-RESPONSE1\n{hello}\n{initiator_signature}\n{responder_nonce}\n{responded_timestamp}"
        );
        let responder_signature = test_signature(responder_identity, &response);
        let acknowledgement =
            format!("SPARK-CLUSTER-FABRIC-ACK1\n{response}\n{responder_signature}");
        let acknowledgement_signature = test_signature(initiator_identity, &acknowledgement);
        let completion = format!(
            "SPARK-CLUSTER-FABRIC-COMPLETE1\n{acknowledgement}\n{acknowledgement_signature}"
        );
        let completion_signature = test_signature(responder_identity, &completion);
        let transcript = format!("{completion}\n{completion_signature}");
        let proof_canonical = format!(
            "SPARK-CLUSTER-FABRIC-PROOF1\n{transcript}\n{}\n{observed_timestamp}",
            identity.node_id()
        );
        Ok(ClusterFabricAuthenticationProof {
            version: 1,
            transaction_id: proposal.transaction_id,
            cluster_id: proposal.cluster_id,
            proposal_digest: proposal.digest()?,
            member_node_id: identity.node_id(),
            initiator_node_id: initiator.node_id,
            responder_node_id: responder.node_id,
            initiator_address,
            responder_address,
            initiator_authority_public_key: initiator.authority_public_key.clone(),
            responder_authority_public_key: responder.authority_public_key.clone(),
            initiator_nonce,
            responder_nonce,
            initiated_at: timestamp,
            responded_at: responded_timestamp,
            initiator_signature,
            responder_signature,
            acknowledgement_signature,
            completion_signature,
            observed_at: observed_timestamp,
            authority_signature: test_signature(identity, &proof_canonical),
        })
    }
}

impl ClusterCollectiveControl for RecordingCollective {
    fn run(
        &self,
        proposal: &ClusterProposal,
        local_node_id: Uuid,
    ) -> Result<ClusterCollectiveProof, CoordinationError> {
        *self.calls.lock().unwrap() += 1;
        Ok(ClusterCollectiveProof {
            version: 1,
            transaction_id: proposal.transaction_id,
            cluster_id: proposal.cluster_id,
            proposal_digest: proposal.digest()?,
            member_node_id: local_node_id,
            node_rank: u8::from(local_node_id != proposal.coordinator_node_id),
            measured_latency_us: self.latency_us.lock().unwrap().unwrap_or(250),
            measured_bandwidth_mbps: self.bandwidth_mbps.lock().unwrap().unwrap_or(100_000),
            operation_elapsed_ms: self.elapsed_ms.lock().unwrap().unwrap_or(0),
            fabric_authentication: None,
            observed_at: String::new(),
            authority_signature: String::new(),
        })
    }
}

fn ready_pair(
    first: &MemberFixture,
    second: &MemberFixture,
    proposal: &ClusterProposal,
    grants: &[sparkd::cluster_coordination::ClusterDeviceGrant],
    now: OffsetDateTime,
) -> Vec<ClusterLinkProof> {
    first.service.activate(proposal, now).unwrap();
    second.service.activate(proposal, now).unwrap();
    let proofs = vec![
        first.service.prove(proposal, now).unwrap(),
        second.service.prove(proposal, now).unwrap(),
    ];
    let collectives = vec![
        first.service.run_collective(proposal, now).unwrap(),
        second.service.run_collective(proposal, now).unwrap(),
    ];
    let receipts = vec![
        first
            .service
            .commit(proposal, grants, &proofs, &collectives, now)
            .unwrap(),
        second
            .service
            .commit(proposal, grants, &proofs, &collectives, now)
            .unwrap(),
    ];
    first.service.finalize(proposal, &receipts, now).unwrap();
    second.service.finalize(proposal, &receipts, now).unwrap();
    proofs
}

#[derive(Default)]
struct RecordingRuntime {
    starts: StdMutex<Vec<(Uuid, Uuid, Uuid)>>,
    stops: StdMutex<Vec<(Uuid, Uuid)>>,
    fail: StdMutex<bool>,
    fail_start: StdMutex<bool>,
    fail_health: StdMutex<bool>,
}

impl DistributedRuntimeControl for RecordingRuntime {
    fn start(
        &self,
        proposal: &ClusterProposal,
        local_node_id: Uuid,
        launch_id: Uuid,
        _: &DistributedExecutionSpec,
    ) -> Result<(), CoordinationError> {
        self.starts
            .lock()
            .unwrap()
            .push((proposal.cluster_id, launch_id, local_node_id));
        if *self.fail_start.lock().unwrap() {
            Err(CoordinationError::Runtime("scripted start failure".into()))
        } else {
            Ok(())
        }
    }

    fn healthy(&self, _: &ClusterProposal, _: Uuid, _: Uuid) -> Result<bool, CoordinationError> {
        Ok(!*self.fail_health.lock().unwrap())
    }

    fn stop(&self, cluster_id: Uuid, launch_id: Uuid) -> Result<(), CoordinationError> {
        self.stops.lock().unwrap().push((cluster_id, launch_id));
        if *self.fail.lock().unwrap() {
            Err(CoordinationError::Runtime("scripted stop failure".into()))
        } else {
            Ok(())
        }
    }
}

fn execution_spec(launch_id: Uuid) -> DistributedExecutionSpec {
    DistributedExecutionSpec {
        recipe_id: "owner/deepseek".into(),
        profile_id: "tp2".into(),
        recipe_digest: "a".repeat(64),
        source_revision: "b".repeat(40),
        image_digest: format!("vllm@sha256:{}", "c".repeat(64)),
        served_name: "deepseek".into(),
        model_snapshot: "/var/lib/spark-runtime/models/snapshots/owner/deepseek/revision".into(),
        host_port: 18_100 + ((launch_id.as_u128() as u32) % 100) as u16,
        gpu_memory_utilisation_milli: 700,
        max_model_length: 8_192,
        max_sequences: 8,
        max_batched_tokens: 16_384,
        tensor_parallel_size: 2,
    }
}

struct MemberFixture {
    identity: Arc<NodeIdentity>,
    database: Arc<Mutex<Connection>>,
    link: Arc<RecordingLink>,
    runtime: Arc<RecordingRuntime>,
    collective: Arc<RecordingCollective>,
    authenticator: Arc<RecordingPeerAuthenticator>,
    events: EventBus,
    service: ClusterCoordinationService,
}

fn member(
    identity: Arc<NodeIdentity>,
    authenticator: Arc<RecordingPeerAuthenticator>,
    owner: Uuid,
    owner_spki: &[u8],
) -> MemberFixture {
    let mut connection = Connection::open_in_memory().unwrap();
    sparkd::migration::migrate(&mut connection).unwrap();
    sparkd::store::insert_device(
        &connection,
        &owner,
        "Cluster owner",
        "ios",
        owner_spki,
        &sparkd::crypto::sha256_hex(owner_spki),
        "owner",
    )
    .unwrap();
    let database = Arc::new(Mutex::new(connection));
    let link = Arc::new(RecordingLink::default());
    let runtime = Arc::new(RecordingRuntime::default());
    let collective = Arc::new(RecordingCollective::default());
    let events = EventBus::new();
    let service = ClusterCoordinationService::new(
        database.clone(),
        identity.clone(),
        link.clone(),
        runtime.clone(),
    )
    .with_collective(collective.clone())
    .with_peer_authenticator(authenticator.clone())
    .with_events(events.clone())
    .with_runtime_version("0.1.0")
    .with_engine_image(Some(
        "vllm@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa".into(),
    ));
    MemberFixture {
        identity,
        database,
        link,
        runtime,
        collective,
        authenticator,
        events,
        service,
    }
}

fn descriptor(identity: &NodeIdentity) -> ClusterMemberDescriptor {
    ClusterMemberDescriptor {
        node_id: identity.node_id(),
        name: identity.public.node_name.clone(),
        authority_public_key: identity.public.authority_public_key.clone(),
        authority_fingerprint: identity.public.authority_fingerprint.clone(),
        runtime_version: "0.1.0".into(),
        engine_image:
            "vllm@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa".into(),
    }
}

fn proposal(
    first: &MemberFixture,
    second: &MemberFixture,
    owner: Uuid,
    now: OffsetDateTime,
) -> ClusterProposal {
    ClusterProposal {
        version: 1,
        transaction_id: Uuid::new_v4(),
        cluster_id: Uuid::new_v4(),
        name: "Studio pair".into(),
        coordinator_node_id: first.identity.node_id(),
        owner_device_id: owner,
        expires_at: (now + time::Duration::minutes(5))
            .format(&time::format_description::well_known::Rfc3339)
            .unwrap(),
        members: vec![descriptor(&first.identity), descriptor(&second.identity)],
    }
}

fn pair() -> (MemberFixture, MemberFixture, Uuid, Vec<u8>, OffsetDateTime) {
    let owner = Uuid::new_v4();
    let owner_key = p256::ecdsa::SigningKey::random(&mut p256::elliptic_curve::rand_core::OsRng);
    let owner_spki = owner_key
        .verifying_key()
        .to_public_key_der()
        .unwrap()
        .as_bytes()
        .to_vec();
    let first_identity = Arc::new(NodeIdentity::generate("Spark one"));
    let second_identity = Arc::new(NodeIdentity::generate("Spark two"));
    let authenticator = Arc::new(RecordingPeerAuthenticator {
        identities: HashMap::from([
            (first_identity.node_id(), first_identity.as_ref().clone()),
            (second_identity.node_id(), second_identity.as_ref().clone()),
        ]),
    });
    (
        member(first_identity, authenticator.clone(), owner, &owner_spki),
        member(second_identity, authenticator, owner, &owner_spki),
        owner,
        owner_spki,
        OffsetDateTime::now_utc(),
    )
}

include!(
    "cluster_coordination/scenarios/two_members_prepare_and_commit_the_same_signed_grant_set.rs"
);

include!(
    "cluster_coordination/scenarios/reciprocal_mac_and_collective_evidence_without_nonce_authentication_never_commit.rs"
);

include!(
    "cluster_coordination/scenarios/relayed_nonce_transcript_from_another_transaction_is_rejected.rs"
);

include!(
    "cluster_coordination/scenarios/a_substituted_member_signature_never_commits_or_activates_the_link.rs"
);

include!(
    "cluster_coordination/scenarios/prepare_is_idempotent_and_transaction_ids_cannot_be_rebound.rs"
);

include!(
    "cluster_coordination/scenarios/an_interrupted_prepare_rolls_back_its_owned_profile_before_retrying.rs"
);

include!(
    "cluster_coordination/scenarios/unproven_prepare_cleanup_stays_fenced_until_reconciliation_succeeds.rs"
);

include!("cluster_coordination/scenarios/every_side_effecting_phase_is_idempotent.rs");

include!(
    "cluster_coordination/scenarios/measured_latency_and_bandwidth_are_required_before_commit.rs"
);

include!(
    "cluster_coordination/scenarios/bounded_slow_collective_is_timestamped_at_completion_and_remains_committable.rs"
);

include!(
    "cluster_coordination/scenarios/transactional_cluster_events_are_durable_live_monotonic_and_idempotent.rs"
);

fn cluster_events(database: &Arc<Mutex<Connection>>) -> Vec<(i64, String)> {
    let connection = database.lock();
    let mut statement = connection
        .prepare(
            "SELECT sequence,event_type FROM events
             WHERE event_type LIKE 'cluster.%' ORDER BY sequence",
        )
        .unwrap();
    statement
        .query_map([], |row| Ok((row.get(0)?, row.get(1)?)))
        .unwrap()
        .collect::<Result<Vec<_>, _>>()
        .unwrap()
}

include!(
    "cluster_coordination/scenarios/failed_activation_is_rolled_back_and_never_marked_active.rs"
);

include!(
    "cluster_coordination/scenarios/local_carrier_without_reciprocal_peer_identity_never_reaches_ready.rs"
);

include!(
    "cluster_coordination/scenarios/incomplete_or_duplicate_collective_evidence_never_reaches_ready.rs"
);

include!("cluster_coordination/scenarios/an_interrupted_commit_resumes_from_its_durable_fence.rs");

include!(
    "cluster_coordination/scenarios/worker_loss_stops_distributed_work_but_retains_cluster_evidence.rs"
);

include!(
    "cluster_coordination/scenarios/coordinator_loss_requires_promotion_and_never_destroys_membership.rs"
);

include!(
    "cluster_coordination/scenarios/an_unproven_stop_is_retried_after_restart_until_the_launch_fence_releases.rs"
);

include!(
    "cluster_coordination/scenarios/distributed_launch_starts_once_per_member_and_replay_is_safe.rs"
);

include!(
    "cluster_coordination/scenarios/launch_stays_preparing_until_two_member_health_is_proved.rs"
);

include!("cluster_coordination/scenarios/one_cluster_refuses_a_second_active_launch_id.rs");

include!("cluster_coordination/scenarios/failed_distributed_start_is_stopped_and_fenced_failed.rs");

include!(
    "cluster_coordination/scenarios/three_peer_probe_failures_stop_work_and_leave_a_degraded_cluster.rs"
);

include!(
    "cluster_coordination/scenarios/a_dead_local_runtime_is_never_misreported_as_peer_loss.rs"
);

include!("cluster_coordination/scenarios/expired_prepared_proposal_cannot_activate_its_link.rs");

include!(
    "cluster_coordination/scenarios/ambiguous_proposal_fields_are_rejected_and_local_software_is_immutable.rs"
);

include!(
    "cluster_coordination/scenarios/another_live_transaction_or_existing_cluster_blocks_prepare.rs"
);

include!(
    "cluster_coordination/scenarios/rollback_resumes_from_rolling_back_and_removes_committed_membership.rs"
);

include!(
    "cluster_coordination/scenarios/app_exit_between_member_commits_expires_to_standalone_on_both_nodes.rs"
);

include!(
    "cluster_coordination/scenarios/coordinator_compensation_after_split_finalize_rolls_back_both_members.rs"
);

include!(
    "cluster_coordination/scenarios/retained_cluster_grants_preserve_every_signed_expiry_bound.rs"
);
