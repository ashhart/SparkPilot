use super::*;

pub(super) struct ProposalValidation<'a> {
    pub(super) identity: &'a NodeIdentity,
    pub(super) runtime_version: &'a Option<String>,
    pub(super) engine_image: &'a Option<String>,
}

impl ProposalValidation<'_> {
    pub(super) fn local_descriptor(
        &self,
        runtime_version: &str,
    ) -> Result<ClusterMemberDescriptor, CoordinationError> {
        let configured_runtime = self.runtime_version.as_deref().ok_or_else(|| {
            CoordinationError::Conflict("the local runtime version is unavailable".into())
        })?;
        if runtime_version != configured_runtime {
            return Err(CoordinationError::Conflict(
                "the advertised runtime version changed during startup".into(),
            ));
        }
        let engine_image = self.engine_image.clone().ok_or_else(|| {
            CoordinationError::Conflict(
                "no digest-pinned distributed engine image is configured".into(),
            )
        })?;
        Ok(ClusterMemberDescriptor {
            node_id: self.identity.node_id(),
            name: self.identity.public.node_name.clone(),
            authority_public_key: self.identity.public.authority_public_key.clone(),
            authority_fingerprint: self.identity.public.authority_fingerprint.clone(),
            runtime_version: configured_runtime.to_owned(),
            engine_image,
        })
    }

    pub(super) fn verify_grant_set(
        &self,
        proposal: &ClusterProposal,
        grants: &[ClusterDeviceGrant],
        now: OffsetDateTime,
    ) -> Result<(), CoordinationError> {
        if grants.len() != proposal.members.len() {
            return Err(CoordinationError::InvalidGrant(
                "one grant from every member is required".into(),
            ));
        }
        let mut seen = HashSet::new();
        let mut device_fingerprint: Option<&str> = None;
        for grant in grants {
            if !seen.insert(grant.member_node_id) {
                return Err(CoordinationError::InvalidGrant(
                    "duplicate member grant".into(),
                ));
            }
            let member = proposal
                .members
                .iter()
                .find(|member| member.node_id == grant.member_node_id)
                .ok_or_else(|| {
                    CoordinationError::InvalidGrant("grant came from another node".into())
                })?;
            grant.verify(proposal, member, now)?;
            if device_fingerprint
                .replace(&grant.device_key_fingerprint)
                .is_some_and(|fingerprint| fingerprint != grant.device_key_fingerprint)
            {
                return Err(CoordinationError::InvalidGrant(
                    "member grants name different Apple device keys".into(),
                ));
            }
        }
        Ok(())
    }

    pub(super) fn verify_proof_set(
        &self,
        proposal: &ClusterProposal,
        proofs: &[ClusterLinkProof],
        now: OffsetDateTime,
    ) -> Result<(), CoordinationError> {
        if proofs.len() != proposal.members.len() {
            return Err(CoordinationError::InvalidGrant(
                "one current link proof from every member is required".into(),
            ));
        }
        let mut seen = HashSet::new();
        for proof in proofs {
            if !seen.insert(proof.member_node_id) {
                return Err(CoordinationError::InvalidGrant(
                    "duplicate member link proof".into(),
                ));
            }
            let member = proposal
                .members
                .iter()
                .find(|member| member.node_id == proof.member_node_id)
                .ok_or_else(|| {
                    CoordinationError::InvalidGrant("proof came from another node".into())
                })?;
            proof.verify(proposal, member, now)?;
        }
        for proof in proofs {
            let peer = proofs
                .iter()
                .find(|candidate| candidate.member_node_id == proof.peer_node_id)
                .ok_or_else(|| {
                    CoordinationError::InvalidGrant("reciprocal proof is absent".into())
                })?;
            if !proof.neighbour_mac.eq_ignore_ascii_case(&peer.local_mac)
                || proof.local_address != peer.peer_address
                || proof.peer_address != peer.local_address
            {
                return Err(CoordinationError::InvalidGrant(
                    "member proofs do not describe the same physical link".into(),
                ));
            }
        }
        Ok(())
    }

    pub(super) fn verify_collective_set(
        &self,
        proposal: &ClusterProposal,
        proofs: &[ClusterCollectiveProof],
        now: OffsetDateTime,
    ) -> Result<(), CoordinationError> {
        if proofs.len() != proposal.members.len() {
            return Err(CoordinationError::InvalidGrant(
                "one two-rank collective proof from every member is required".into(),
            ));
        }
        let mut members = HashSet::new();
        let mut ranks = HashSet::new();
        for proof in proofs {
            if !members.insert(proof.member_node_id) || !ranks.insert(proof.node_rank) {
                return Err(CoordinationError::InvalidGrant(
                    "collective proofs contain a duplicate member or rank".into(),
                ));
            }
            let member = proposal
                .members
                .iter()
                .find(|member| member.node_id == proof.member_node_id)
                .ok_or_else(|| {
                    CoordinationError::InvalidGrant("collective came from another node".into())
                })?;
            proof.verify(proposal, member, now)?;
        }
        let transcripts = proofs
            .iter()
            .filter_map(|proof| proof.fabric_authentication.as_ref())
            .map(ClusterFabricAuthenticationProof::transcript_canonical)
            .collect::<HashSet<_>>();
        if transcripts.len() != 1 {
            return Err(CoordinationError::InvalidGrant(
                "members did not attest the same live fabric challenge".into(),
            ));
        }
        if ranks != HashSet::from([0, 1]) {
            return Err(CoordinationError::InvalidGrant(
                "collective did not include ranks zero and one".into(),
            ));
        }
        Ok(())
    }

    pub(super) fn verify_receipt_set(
        &self,
        proposal: &ClusterProposal,
        receipts: &[ClusterCommitReceipt],
        now: OffsetDateTime,
    ) -> Result<(), CoordinationError> {
        if receipts.len() != proposal.members.len() {
            return Err(CoordinationError::InvalidGrant(
                "one commit receipt from every member is required".into(),
            ));
        }
        let mut seen = HashSet::new();
        for receipt in receipts {
            if !seen.insert(receipt.member_node_id) {
                return Err(CoordinationError::InvalidGrant(
                    "duplicate member commit receipt".into(),
                ));
            }
            let member = proposal
                .members
                .iter()
                .find(|member| member.node_id == receipt.member_node_id)
                .ok_or_else(|| {
                    CoordinationError::InvalidGrant("commit receipt came from another node".into())
                })?;
            receipt.verify(proposal, member, now)?;
        }
        Ok(())
    }

    pub(super) fn validate_proposal(
        &self,
        proposal: &ClusterProposal,
        now: OffsetDateTime,
    ) -> Result<(), CoordinationError> {
        proposal.validate_for(self.identity, now)?;
        self.validate_local_software(proposal)
    }

    pub(super) fn validate_local_software(
        &self,
        proposal: &ClusterProposal,
    ) -> Result<(), CoordinationError> {
        let local = proposal
            .members
            .iter()
            .find(|member| member.node_id == self.identity.node_id())
            .ok_or_else(|| CoordinationError::InvalidProposal("local Spark is absent".into()))?;
        if self.runtime_version.as_deref() != Some(local.runtime_version.as_str())
            || self.engine_image.as_deref() != Some(local.engine_image.as_str())
        {
            return Err(CoordinationError::InvalidProposal(
                "the proposal does not match this Spark's configured runtime and engine image"
                    .into(),
            ));
        }
        Ok(())
    }
}
