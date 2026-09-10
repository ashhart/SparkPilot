use super::*;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct ClusterCollectiveProof {
    pub version: u32,
    pub transaction_id: Uuid,
    pub cluster_id: Uuid,
    pub proposal_digest: String,
    pub member_node_id: Uuid,
    pub node_rank: u8,
    pub measured_latency_us: u64,
    pub measured_bandwidth_mbps: u64,
    pub operation_elapsed_ms: u64,
    pub fabric_authentication: Option<ClusterFabricAuthenticationProof>,
    pub observed_at: String,
    pub authority_signature: String,
}

impl ClusterCollectiveProof {
    pub(super) fn canonical_without_signature(&self) -> String {
        let fabric_digest = self
            .fabric_authentication
            .as_ref()
            .map(|proof| {
                format!(
                    "{:x}",
                    Sha256::digest(proof.transcript_canonical().as_bytes())
                )
            })
            .unwrap_or_else(|| "absent".into());
        format!(
            "SPARK-CLUSTER-COLLECTIVE-PROOF1\n{}\n{}\n{}\n{}\n{}\n{}\n{}\n{}\n{}\n{}",
            self.transaction_id,
            self.cluster_id,
            self.proposal_digest,
            self.member_node_id,
            self.node_rank,
            self.measured_latency_us,
            self.measured_bandwidth_mbps,
            self.operation_elapsed_ms,
            fabric_digest,
            self.observed_at
        )
    }

    pub(super) fn verify(
        &self,
        proposal: &ClusterProposal,
        member: &ClusterMemberDescriptor,
        now: OffsetDateTime,
    ) -> Result<(), CoordinationError> {
        let expected_rank = u8::from(member.node_id != proposal.coordinator_node_id);
        let observed = OffsetDateTime::parse(
            &self.observed_at,
            &time::format_description::well_known::Rfc3339,
        )
        .map_err(|_| CoordinationError::InvalidGrant("collective proof time is invalid".into()))?;
        if self.version != PROPOSAL_VERSION
            || self.transaction_id != proposal.transaction_id
            || self.cluster_id != proposal.cluster_id
            || self.proposal_digest != proposal.digest()?
            || self.member_node_id != member.node_id
            || self.node_rank != expected_rank
            || self.measured_latency_us > 5_000
            || self.measured_bandwidth_mbps < 10_000
            || self.operation_elapsed_ms > 190_000
            || observed > now
            || now - observed > time::Duration::minutes(5)
        {
            return Err(CoordinationError::InvalidGrant(
                "collective proof does not match the active proposal".into(),
            ));
        }
        let fabric = self.fabric_authentication.as_ref().ok_or_else(|| {
            CoordinationError::InvalidGrant(
                "collective proof has no live fabric authentication".into(),
            )
        })?;
        // Verify live exchanges against completion time rather than the earlier request timestamp.
        fabric.verify(proposal, member, fabric.verification_instant(now))?;
        let bytes = crate::crypto::base64url_decode(&self.authority_signature).map_err(|_| {
            CoordinationError::InvalidGrant("collective signature is not base64url".into())
        })?;
        let signature = Signature::from_slice(&bytes).map_err(|_| {
            CoordinationError::InvalidGrant("collective signature length is invalid".into())
        })?;
        decode_verifying_key(&member.authority_public_key)?
            .verify(self.canonical_without_signature().as_bytes(), &signature)
            .map_err(|_| {
                CoordinationError::InvalidGrant("collective signature was rejected".into())
            })
    }
}

pub trait ClusterCollectiveControl: Send + Sync {
    fn run(
        &self,
        proposal: &ClusterProposal,
        local_node_id: Uuid,
    ) -> Result<ClusterCollectiveProof, CoordinationError>;
}

pub trait ClusterPeerAuthenticator: Send + Sync {
    fn authenticate(
        &self,
        proposal: &ClusterProposal,
        identity: &NodeIdentity,
        now: OffsetDateTime,
    ) -> Result<ClusterFabricAuthenticationProof, CoordinationError>;
}
