use super::*;

pub(super) const PROPOSAL_VERSION: u32 = 1;

pub(super) const FABRIC_PREFIX: [u8; 3] = [172, 31, 252];

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct ClusterMemberDescriptor {
    pub node_id: Uuid,
    pub name: String,
    pub authority_public_key: String,
    pub authority_fingerprint: String,
    pub runtime_version: String,
    pub engine_image: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct ClusterProposal {
    pub version: u32,
    pub transaction_id: Uuid,
    pub cluster_id: Uuid,
    pub name: String,
    pub coordinator_node_id: Uuid,
    pub owner_device_id: Uuid,
    pub expires_at: String,
    pub members: Vec<ClusterMemberDescriptor>,
}

impl ClusterProposal {
    pub fn canonical(&self) -> Result<String, CoordinationError> {
        self.validate_shape()?;
        let mut members = self.members.clone();
        members.sort_by_key(|member| member.node_id);
        let mut text = String::from("SPARK-CLUSTER-PROPOSAL1\n");
        for field in [
            self.transaction_id.to_string(),
            self.cluster_id.to_string(),
            self.name.clone(),
            self.coordinator_node_id.to_string(),
            self.owner_device_id.to_string(),
            self.expires_at.clone(),
        ] {
            push_canonical_field(&mut text, &field);
        }
        for member in members {
            for field in [
                member.node_id.to_string(),
                member.name,
                member.authority_public_key,
                member.authority_fingerprint,
                member.runtime_version,
                member.engine_image,
            ] {
                push_canonical_field(&mut text, &field);
            }
        }
        Ok(text)
    }

    pub fn digest(&self) -> Result<String, CoordinationError> {
        Ok(hex::encode(Sha256::digest(self.canonical()?.as_bytes())))
    }

    pub fn validate_for(
        &self,
        identity: &NodeIdentity,
        now: OffsetDateTime,
    ) -> Result<(), CoordinationError> {
        self.validate_shape()?;
        let expiry = OffsetDateTime::parse(
            &self.expires_at,
            &time::format_description::well_known::Rfc3339,
        )
        .map_err(|_| CoordinationError::InvalidProposal("expiry is not RFC3339".into()))?;
        if expiry <= now || expiry > now + time::Duration::minutes(10) {
            return Err(CoordinationError::InvalidProposal(
                "expiry must be within the next ten minutes".into(),
            ));
        }
        let local = self
            .members
            .iter()
            .find(|member| member.node_id == identity.node_id())
            .ok_or_else(|| CoordinationError::InvalidProposal("local Spark is absent".into()))?;
        if local.authority_public_key != identity.public.authority_public_key
            || local.authority_fingerprint != identity.public.authority_fingerprint
        {
            return Err(CoordinationError::InvalidProposal(
                "local node authority does not match the proposal".into(),
            ));
        }
        Ok(())
    }

    fn validate_shape(&self) -> Result<(), CoordinationError> {
        if self.version != PROPOSAL_VERSION {
            return Err(CoordinationError::InvalidProposal(
                "unsupported proposal version".into(),
            ));
        }
        if self.members.len() != super::MAXIMUM_SUPPORTED_MEMBERS {
            return Err(CoordinationError::InvalidProposal(
                "the shipping managed-cluster transaction requires exactly two Sparks".into(),
            ));
        }
        if self.name.trim().is_empty()
            || self.name.len() > 120
            || self.name != self.name.trim()
            || self.name.chars().any(char::is_control)
        {
            return Err(CoordinationError::InvalidProposal(
                "name must contain 1 to 120 trimmed characters".into(),
            ));
        }
        let ids = self
            .members
            .iter()
            .map(|member| member.node_id)
            .collect::<HashSet<_>>();
        if ids.len() != self.members.len() || !ids.contains(&self.coordinator_node_id) {
            return Err(CoordinationError::InvalidProposal(
                "members must be unique and include the coordinator".into(),
            ));
        }
        let first_runtime = &self.members[0].runtime_version;
        let first_image = &self.members[0].engine_image;
        for member in &self.members {
            if member.name.trim().is_empty()
                || member.name.len() > 120
                || member.name.chars().any(char::is_control)
                || member.authority_public_key.len() != 64
                || member.authority_fingerprint.len() != 64
                || member.runtime_version.is_empty()
                || member.runtime_version.len() > 64
                || member.runtime_version != member.runtime_version.trim()
                || member.runtime_version.chars().any(char::is_control)
                || member.engine_image.len() > 584
                || !spark_privd::protocol::valid_pinned_image(&member.engine_image)
                || member.runtime_version != *first_runtime
                || member.engine_image != *first_image
            {
                return Err(CoordinationError::InvalidProposal(
                    "member identity or software compatibility is invalid".into(),
                ));
            }
            let key = decode_verifying_key(&member.authority_public_key)?;
            if hex::encode(Sha256::digest(key.to_bytes())) != member.authority_fingerprint {
                return Err(CoordinationError::InvalidProposal(
                    "member authority fingerprint does not match its key".into(),
                ));
            }
        }
        Ok(())
    }

    pub fn addresses_for(&self, node_id: Uuid) -> Result<(Ipv4Addr, Ipv4Addr), CoordinationError> {
        if self.members.len() != super::MAXIMUM_SUPPORTED_MEMBERS {
            return Err(CoordinationError::InvalidProposal(
                "the shipping CX-7 transaction supports exactly two members".into(),
            ));
        }
        let mut ids = self
            .members
            .iter()
            .map(|member| member.node_id)
            .collect::<Vec<_>>();
        ids.sort();
        let local_index = ids
            .iter()
            .position(|candidate| *candidate == node_id)
            .ok_or_else(|| CoordinationError::InvalidProposal("local Spark is absent".into()))?;
        let addresses = [
            Ipv4Addr::new(FABRIC_PREFIX[0], FABRIC_PREFIX[1], FABRIC_PREFIX[2], 1),
            Ipv4Addr::new(FABRIC_PREFIX[0], FABRIC_PREFIX[1], FABRIC_PREFIX[2], 2),
        ];
        Ok((addresses[local_index], addresses[1 - local_index]))
    }
}

pub(super) fn push_canonical_field(output: &mut String, value: &str) {
    output.push_str(&value.len().to_string());
    output.push(':');
    output.push_str(value);
    output.push('\n');
}
