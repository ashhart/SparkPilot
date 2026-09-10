use super::*;

/// Bind a live nonce exchange on the proposed /30 path with independent signatures from both members.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct ClusterFabricAuthenticationProof {
    pub version: u32,
    pub transaction_id: Uuid,
    pub cluster_id: Uuid,
    pub proposal_digest: String,
    pub member_node_id: Uuid,
    pub initiator_node_id: Uuid,
    pub responder_node_id: Uuid,
    pub initiator_address: Ipv4Addr,
    pub responder_address: Ipv4Addr,
    pub initiator_authority_public_key: String,
    pub responder_authority_public_key: String,
    pub initiator_nonce: String,
    pub responder_nonce: String,
    pub initiated_at: String,
    pub responded_at: String,
    pub initiator_signature: String,
    pub responder_signature: String,
    pub acknowledgement_signature: String,
    pub completion_signature: String,
    pub observed_at: String,
    pub authority_signature: String,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub(super) struct FabricChallengeHello {
    pub(super) version: u32,
    pub(super) transaction_id: Uuid,
    pub(super) cluster_id: Uuid,
    pub(super) proposal_digest: String,
    pub(super) initiator_node_id: Uuid,
    pub(super) responder_node_id: Uuid,
    pub(super) initiator_address: Ipv4Addr,
    pub(super) responder_address: Ipv4Addr,
    pub(super) initiator_authority_public_key: String,
    pub(super) responder_authority_public_key: String,
    pub(super) initiator_nonce: String,
    pub(super) initiated_at: String,
    pub(super) initiator_signature: String,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub(super) struct FabricChallengeResponse {
    pub(super) responder_nonce: String,
    pub(super) responded_at: String,
    pub(super) responder_signature: String,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub(super) struct FabricChallengeAcknowledgement {
    pub(super) acknowledgement_signature: String,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub(super) struct FabricChallengeCompletion {
    pub(super) completion_signature: String,
}

impl FabricChallengeHello {
    pub(super) fn canonical_without_signature(&self) -> String {
        format!(
            "SPARK-CLUSTER-FABRIC-HELLO1\n{}\n{}\n{}\n{}\n{}\n{}\n{}\n{}\n{}\n{}\n{}",
            self.transaction_id,
            self.cluster_id,
            self.proposal_digest,
            self.initiator_node_id,
            self.responder_node_id,
            self.initiator_address,
            self.responder_address,
            self.initiator_authority_public_key,
            self.responder_authority_public_key,
            self.initiator_nonce,
            self.initiated_at,
        )
    }

    pub(super) fn response_canonical(&self, response: &FabricChallengeResponse) -> String {
        format!(
            "SPARK-CLUSTER-FABRIC-RESPONSE1\n{}\n{}\n{}\n{}",
            self.canonical_without_signature(),
            self.initiator_signature,
            response.responder_nonce,
            response.responded_at,
        )
    }

    pub(super) fn acknowledgement_canonical(&self, response: &FabricChallengeResponse) -> String {
        format!(
            "SPARK-CLUSTER-FABRIC-ACK1\n{}\n{}",
            self.response_canonical(response),
            response.responder_signature,
        )
    }

    pub(super) fn completion_canonical(
        &self,
        response: &FabricChallengeResponse,
        acknowledgement: &FabricChallengeAcknowledgement,
    ) -> String {
        format!(
            "SPARK-CLUSTER-FABRIC-COMPLETE1\n{}\n{}",
            self.acknowledgement_canonical(response),
            acknowledgement.acknowledgement_signature,
        )
    }
}

impl ClusterFabricAuthenticationProof {
    /// Use the later request or observation instant; verification still bounds the complete exchange to five minutes from initiation.
    pub fn verification_instant(&self, now: OffsetDateTime) -> OffsetDateTime {
        OffsetDateTime::parse(
            &self.observed_at,
            &time::format_description::well_known::Rfc3339,
        )
        .map_or(now, |observed| observed.max(now))
    }

    fn hello(&self) -> FabricChallengeHello {
        FabricChallengeHello {
            version: self.version,
            transaction_id: self.transaction_id,
            cluster_id: self.cluster_id,
            proposal_digest: self.proposal_digest.clone(),
            initiator_node_id: self.initiator_node_id,
            responder_node_id: self.responder_node_id,
            initiator_address: self.initiator_address,
            responder_address: self.responder_address,
            initiator_authority_public_key: self.initiator_authority_public_key.clone(),
            responder_authority_public_key: self.responder_authority_public_key.clone(),
            initiator_nonce: self.initiator_nonce.clone(),
            initiated_at: self.initiated_at.clone(),
            initiator_signature: self.initiator_signature.clone(),
        }
    }

    fn response(&self) -> FabricChallengeResponse {
        FabricChallengeResponse {
            responder_nonce: self.responder_nonce.clone(),
            responded_at: self.responded_at.clone(),
            responder_signature: self.responder_signature.clone(),
        }
    }

    fn acknowledgement(&self) -> FabricChallengeAcknowledgement {
        FabricChallengeAcknowledgement {
            acknowledgement_signature: self.acknowledgement_signature.clone(),
        }
    }

    pub(super) fn transcript_canonical(&self) -> String {
        let hello = self.hello();
        let response = self.response();
        let acknowledgement = self.acknowledgement();
        format!(
            "{}\n{}",
            hello.completion_canonical(&response, &acknowledgement),
            self.completion_signature,
        )
    }

    pub(super) fn canonical_without_signature(&self) -> String {
        format!(
            "SPARK-CLUSTER-FABRIC-PROOF1\n{}\n{}\n{}",
            self.transcript_canonical(),
            self.member_node_id,
            self.observed_at,
        )
    }

    pub(super) fn verify(
        &self,
        proposal: &ClusterProposal,
        member: &ClusterMemberDescriptor,
        now: OffsetDateTime,
    ) -> Result<(), CoordinationError> {
        let mut ordered = proposal.members.iter().collect::<Vec<_>>();
        ordered.sort_by_key(|candidate| candidate.node_id);
        let responder = ordered[0];
        let initiator = ordered[1];
        let (initiator_address, responder_address) = proposal.addresses_for(initiator.node_id)?;
        let initiated = OffsetDateTime::parse(
            &self.initiated_at,
            &time::format_description::well_known::Rfc3339,
        )
        .map_err(|_| CoordinationError::InvalidGrant("fabric challenge time is invalid".into()))?;
        let responded = OffsetDateTime::parse(
            &self.responded_at,
            &time::format_description::well_known::Rfc3339,
        )
        .map_err(|_| CoordinationError::InvalidGrant("fabric response time is invalid".into()))?;
        let observed = OffsetDateTime::parse(
            &self.observed_at,
            &time::format_description::well_known::Rfc3339,
        )
        .map_err(|_| CoordinationError::InvalidGrant("fabric proof time is invalid".into()))?;
        let nonce_valid = |encoded: &str| {
            crate::crypto::base64url_decode(encoded)
                .is_ok_and(|bytes| bytes.len() == 32 && bytes.iter().any(|byte| *byte != 0))
        };
        if self.version != PROPOSAL_VERSION
            || self.transaction_id != proposal.transaction_id
            || self.cluster_id != proposal.cluster_id
            || self.proposal_digest != proposal.digest()?
            || self.member_node_id != member.node_id
            || self.initiator_node_id != initiator.node_id
            || self.responder_node_id != responder.node_id
            || self.initiator_address != initiator_address
            || self.responder_address != responder_address
            || self.initiator_authority_public_key != initiator.authority_public_key
            || self.responder_authority_public_key != responder.authority_public_key
            || !nonce_valid(&self.initiator_nonce)
            || !nonce_valid(&self.responder_nonce)
            || self.initiator_nonce == self.responder_nonce
            || initiated > responded
            || responded > observed
            || observed > now
            || now - initiated > time::Duration::minutes(5)
        {
            return Err(CoordinationError::InvalidGrant(
                "fabric challenge is not bound to this live proposal".into(),
            ));
        }
        let hello = self.hello();
        let response = self.response();
        let acknowledgement = self.acknowledgement();
        let initiator_key = decode_verifying_key(&initiator.authority_public_key)?;
        let responder_key = decode_verifying_key(&responder.authority_public_key)?;
        verify_authority_signature(
            &hello.initiator_signature,
            &initiator_key,
            hello.canonical_without_signature().as_bytes(),
            "fabric initiator signature",
        )?;
        verify_authority_signature(
            &response.responder_signature,
            &responder_key,
            hello.response_canonical(&response).as_bytes(),
            "fabric responder signature",
        )?;
        verify_authority_signature(
            &acknowledgement.acknowledgement_signature,
            &initiator_key,
            hello.acknowledgement_canonical(&response).as_bytes(),
            "fabric acknowledgement signature",
        )?;
        verify_authority_signature(
            &self.completion_signature,
            &responder_key,
            hello
                .completion_canonical(&response, &acknowledgement)
                .as_bytes(),
            "fabric completion signature",
        )?;
        verify_authority_signature(
            &self.authority_signature,
            &decode_verifying_key(&member.authority_public_key)?,
            self.canonical_without_signature().as_bytes(),
            "fabric proof signature",
        )
    }
}
