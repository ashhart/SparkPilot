use super::*;

/// Cross-check signed local and neighbor MAC evidence across members; carrier alone cannot establish cluster readiness.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct ClusterLinkProof {
    pub version: u32,
    pub transaction_id: Uuid,
    pub cluster_id: Uuid,
    pub proposal_digest: String,
    pub member_node_id: Uuid,
    pub peer_node_id: Uuid,
    pub local_address: Ipv4Addr,
    pub peer_address: Ipv4Addr,
    pub interface: String,
    pub local_mac: String,
    pub neighbour_mac: String,
    pub speed_mbps: u64,
    pub mtu: u64,
    pub observed_at: String,
    pub authority_signature: String,
}

impl ClusterLinkProof {
    pub(super) fn canonical_without_signature(&self) -> String {
        format!(
            "SPARK-CLUSTER-LINK-PROOF1\n{}\n{}\n{}\n{}\n{}\n{}\n{}\n{}\n{}\n{}\n{}\n{}\n{}",
            self.transaction_id,
            self.cluster_id,
            self.proposal_digest,
            self.member_node_id,
            self.peer_node_id,
            self.local_address,
            self.peer_address,
            self.interface,
            self.local_mac,
            self.neighbour_mac,
            self.speed_mbps,
            self.mtu,
            self.observed_at
        )
    }

    pub(super) fn verify(
        &self,
        proposal: &ClusterProposal,
        member: &ClusterMemberDescriptor,
        now: OffsetDateTime,
    ) -> Result<(), CoordinationError> {
        let (local_address, peer_address) = proposal.addresses_for(member.node_id)?;
        let peer_node_id = proposal
            .members
            .iter()
            .find(|candidate| candidate.node_id != member.node_id)
            .map(|candidate| candidate.node_id)
            .ok_or_else(|| CoordinationError::InvalidGrant("proof peer is absent".into()))?;
        let observed = OffsetDateTime::parse(
            &self.observed_at,
            &time::format_description::well_known::Rfc3339,
        )
        .map_err(|_| CoordinationError::InvalidGrant("proof time is invalid".into()))?;
        if self.version != PROPOSAL_VERSION
            || self.transaction_id != proposal.transaction_id
            || self.cluster_id != proposal.cluster_id
            || self.proposal_digest != proposal.digest()?
            || self.member_node_id != member.node_id
            || self.peer_node_id != peer_node_id
            || self.local_address != local_address
            || self.peer_address != peer_address
            || self.speed_mbps < 200_000
            || self.mtu != 9_000
            || self.interface.is_empty()
            || !valid_mac(&self.local_mac)
            || !valid_mac(&self.neighbour_mac)
            || observed > now
            || now - observed > time::Duration::minutes(5)
        {
            return Err(CoordinationError::InvalidGrant(
                "link proof does not match the active proposal".into(),
            ));
        }
        let signature_bytes =
            crate::crypto::base64url_decode(&self.authority_signature).map_err(|_| {
                CoordinationError::InvalidGrant("proof signature is not base64url".into())
            })?;
        let signature = Signature::from_slice(&signature_bytes).map_err(|_| {
            CoordinationError::InvalidGrant("proof signature length is invalid".into())
        })?;
        decode_verifying_key(&member.authority_public_key)?
            .verify(self.canonical_without_signature().as_bytes(), &signature)
            .map_err(|_| CoordinationError::InvalidGrant("proof signature was rejected".into()))
    }
}

pub(super) fn valid_mac(value: &str) -> bool {
    value.len() == 17
        && value.split(':').count() == 6
        && value
            .split(':')
            .all(|octet| octet.len() == 2 && octet.bytes().all(|byte| byte.is_ascii_hexdigit()))
}

#[derive(Deserialize)]
pub(super) struct LinkObservation {
    pub(super) transaction_id: Uuid,
    pub(super) cluster_id: Uuid,
    pub(super) local_node_id: Uuid,
    pub(super) peer_node_id: Uuid,
    pub(super) local_address: Ipv4Addr,
    pub(super) peer_address: Ipv4Addr,
    pub(super) interface: String,
    pub(super) local_mac: String,
    pub(super) neighbour_mac: String,
    pub(super) speed_mbps: u64,
    pub(super) mtu: u64,
}

pub trait ClusterLinkControl: Send + Sync {
    fn apply(
        &self,
        proposal: &ClusterProposal,
        local_node_id: Uuid,
        phase: ClusterLinkPhase,
    ) -> Result<(), CoordinationError>;

    fn prove(
        &self,
        proposal: &ClusterProposal,
        local_node_id: Uuid,
    ) -> Result<ClusterLinkProof, CoordinationError>;
}
