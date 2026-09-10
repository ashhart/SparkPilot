use super::*;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct ClusterDeviceGrant {
    pub version: u32,
    pub transaction_id: Uuid,
    pub cluster_id: Uuid,
    pub proposal_digest: String,
    pub member_node_id: Uuid,
    pub owner_device_id: Uuid,
    pub role: String,
    pub device_key_fingerprint: String,
    pub issued_at: String,
    pub expires_at: String,
    pub authority_signature: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct ClusterCommitReceipt {
    pub version: u32,
    pub transaction_id: Uuid,
    pub cluster_id: Uuid,
    pub proposal_digest: String,
    pub member_node_id: Uuid,
    pub committed_at: String,
    pub authority_signature: String,
}

impl ClusterCommitReceipt {
    pub(super) fn canonical_without_signature(&self) -> String {
        format!(
            "SPARK-CLUSTER-COMMIT-RECEIPT1\n{}\n{}\n{}\n{}\n{}",
            self.transaction_id,
            self.cluster_id,
            self.proposal_digest,
            self.member_node_id,
            self.committed_at
        )
    }

    pub(super) fn verify(
        &self,
        proposal: &ClusterProposal,
        member: &ClusterMemberDescriptor,
        now: OffsetDateTime,
    ) -> Result<(), CoordinationError> {
        let committed = OffsetDateTime::parse(
            &self.committed_at,
            &time::format_description::well_known::Rfc3339,
        )
        .map_err(|_| CoordinationError::InvalidGrant("commit receipt time is invalid".into()))?;
        if self.version != PROPOSAL_VERSION
            || self.transaction_id != proposal.transaction_id
            || self.cluster_id != proposal.cluster_id
            || self.proposal_digest != proposal.digest()?
            || self.member_node_id != member.node_id
            || committed > now
            || now - committed > time::Duration::minutes(2)
        {
            return Err(CoordinationError::InvalidGrant(
                "commit receipt does not match the active proposal".into(),
            ));
        }
        let bytes = crate::crypto::base64url_decode(&self.authority_signature).map_err(|_| {
            CoordinationError::InvalidGrant("commit receipt is not base64url".into())
        })?;
        let signature = Signature::from_slice(&bytes).map_err(|_| {
            CoordinationError::InvalidGrant("commit receipt signature length is invalid".into())
        })?;
        decode_verifying_key(&member.authority_public_key)?
            .verify(self.canonical_without_signature().as_bytes(), &signature)
            .map_err(|_| CoordinationError::InvalidGrant("commit receipt was rejected".into()))
    }
}

pub(super) fn verify_authority_signature(
    encoded: &str,
    key: &VerifyingKey,
    message: &[u8],
    label: &str,
) -> Result<(), CoordinationError> {
    let bytes = crate::crypto::base64url_decode(encoded)
        .map_err(|_| CoordinationError::InvalidGrant(format!("{label} is not base64url")))?;
    let signature = Signature::from_slice(&bytes).map_err(|_| {
        CoordinationError::InvalidGrant(format!("{label} has an invalid signature length"))
    })?;
    key.verify(message, &signature)
        .map_err(|_| CoordinationError::InvalidGrant(format!("{label} was rejected")))
}

impl ClusterDeviceGrant {
    pub(super) fn canonical_without_signature(&self) -> String {
        format!(
            "SPARK-CLUSTER-GRANT1\n{}\n{}\n{}\n{}\n{}\n{}\n{}\n{}\n{}",
            self.transaction_id,
            self.cluster_id,
            self.proposal_digest,
            self.member_node_id,
            self.owner_device_id,
            self.role,
            self.device_key_fingerprint,
            self.issued_at,
            self.expires_at
        )
    }

    pub(super) fn verify(
        &self,
        proposal: &ClusterProposal,
        member: &ClusterMemberDescriptor,
        now: OffsetDateTime,
    ) -> Result<(), CoordinationError> {
        if self.version != PROPOSAL_VERSION
            || self.transaction_id != proposal.transaction_id
            || self.cluster_id != proposal.cluster_id
            || self.member_node_id != member.node_id
            || self.owner_device_id != proposal.owner_device_id
            || self.proposal_digest != proposal.digest()?
            || !matches!(self.role.as_str(), "owner" | "administrator")
        {
            return Err(CoordinationError::InvalidGrant(
                "grant bindings do not match the proposal".into(),
            ));
        }
        let expires = OffsetDateTime::parse(
            &self.expires_at,
            &time::format_description::well_known::Rfc3339,
        )
        .map_err(|_| CoordinationError::InvalidGrant("grant expiry is invalid".into()))?;
        if expires <= now {
            return Err(CoordinationError::InvalidGrant("grant expired".into()));
        }
        let signature_bytes = crate::crypto::base64url_decode(&self.authority_signature)
            .map_err(|_| CoordinationError::InvalidGrant("signature is not base64url".into()))?;
        let signature = Signature::from_slice(&signature_bytes)
            .map_err(|_| CoordinationError::InvalidGrant("signature length is invalid".into()))?;
        decode_verifying_key(&member.authority_public_key)?
            .verify(self.canonical_without_signature().as_bytes(), &signature)
            .map_err(|_| CoordinationError::InvalidGrant("signature was rejected".into()))
    }
}

pub(super) fn decode_verifying_key(encoded: &str) -> Result<VerifyingKey, CoordinationError> {
    let bytes: [u8; 32] = hex::decode(encoded)
        .map_err(|_| CoordinationError::InvalidProposal("authority key is not hex".into()))?
        .try_into()
        .map_err(|_| CoordinationError::InvalidProposal("authority key has wrong length".into()))?;
    VerifyingKey::from_bytes(&bytes)
        .map_err(|_| CoordinationError::InvalidProposal("authority key is invalid".into()))
}
