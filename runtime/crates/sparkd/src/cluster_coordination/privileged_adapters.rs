use super::*;

#[derive(Clone)]
pub struct PrivilegedClusterCollective {
    client: crate::privd::PrivilegedClient,
}

impl PrivilegedClusterCollective {
    pub fn new(client: crate::privd::PrivilegedClient) -> Self {
        Self { client }
    }
}

impl ClusterCollectiveControl for PrivilegedClusterCollective {
    fn run(
        &self,
        proposal: &ClusterProposal,
        local_node_id: Uuid,
    ) -> Result<ClusterCollectiveProof, CoordinationError> {
        let peer_node_id = proposal
            .members
            .iter()
            .find(|member| member.node_id != local_node_id)
            .map(|member| member.node_id)
            .ok_or_else(|| CoordinationError::InvalidProposal("peer is absent".into()))?;
        let (local_address, peer_address) = proposal.addresses_for(local_node_id)?;
        let coordinator_address = proposal.addresses_for(proposal.coordinator_node_id)?.0;
        let node_rank = u8::from(local_node_id != proposal.coordinator_node_id);
        let image_digest = proposal
            .members
            .first()
            .map(|member| member.engine_image.clone())
            .ok_or_else(|| CoordinationError::InvalidProposal("engine image is absent".into()))?;
        let response = self
            .client
            .call(PrivilegedOperation::RunClusterTwoRankTest {
                request_id: Uuid::new_v4(),
                transaction_id: proposal.transaction_id,
                cluster_id: proposal.cluster_id,
                local_node_id,
                peer_node_id,
                local_address,
                peer_address,
                coordinator_address,
                node_rank,
                image_digest,
            })
            .map_err(|error| CoordinationError::Link(error.to_string()))?;
        if !response.accepted
            || response
                .details
                .get("outcome")
                .and_then(serde_json::Value::as_str)
                != Some("passed")
        {
            return Err(CoordinationError::Link(
                "the two-rank NCCL collective did not pass".into(),
            ));
        }
        let metric = |name: &str| {
            response
                .details
                .get(name)
                .and_then(serde_json::Value::as_u64)
                .ok_or_else(|| {
                    CoordinationError::Link(format!("the two-rank NCCL proof omitted {name}"))
                })
        };
        Ok(ClusterCollectiveProof {
            version: PROPOSAL_VERSION,
            transaction_id: proposal.transaction_id,
            cluster_id: proposal.cluster_id,
            proposal_digest: proposal.digest()?,
            member_node_id: local_node_id,
            node_rank,
            measured_latency_us: metric("measured_latency_us")?,
            measured_bandwidth_mbps: metric("measured_bandwidth_mbps")?,
            operation_elapsed_ms: metric("operation_elapsed_ms")?,
            fabric_authentication: None,
            observed_at: String::new(),
            authority_signature: String::new(),
        })
    }
}

#[derive(Clone)]
pub struct PrivilegedClusterLink {
    client: crate::privd::PrivilegedClient,
}

impl PrivilegedClusterLink {
    pub fn new(client: crate::privd::PrivilegedClient) -> Self {
        Self { client }
    }
}

impl ClusterLinkControl for PrivilegedClusterLink {
    fn apply(
        &self,
        proposal: &ClusterProposal,
        local_node_id: Uuid,
        phase: ClusterLinkPhase,
    ) -> Result<(), CoordinationError> {
        let peer = proposal
            .members
            .iter()
            .find(|member| member.node_id != local_node_id)
            .ok_or_else(|| CoordinationError::InvalidProposal("peer is absent".into()))?;
        let (local_address, peer_address) = proposal.addresses_for(local_node_id)?;
        let response = self
            .client
            .call(PrivilegedOperation::ConfigureClusterLink {
                request_id: Uuid::new_v4(),
                transaction_id: proposal.transaction_id,
                cluster_id: proposal.cluster_id,
                local_node_id,
                peer_node_id: peer.node_id,
                local_address,
                peer_address,
                phase,
            })
            .map_err(|error| CoordinationError::Link(error.to_string()))?;
        if !response.accepted {
            return Err(CoordinationError::Link(format!(
                "{}: {}",
                response.code, response.message
            )));
        }
        Ok(())
    }

    fn prove(
        &self,
        proposal: &ClusterProposal,
        local_node_id: Uuid,
    ) -> Result<ClusterLinkProof, CoordinationError> {
        let peer = proposal
            .members
            .iter()
            .find(|member| member.node_id != local_node_id)
            .ok_or_else(|| CoordinationError::InvalidProposal("peer is absent".into()))?;
        let (local_address, peer_address) = proposal.addresses_for(local_node_id)?;
        let response = self
            .client
            .call(PrivilegedOperation::ProbeClusterLink {
                request_id: Uuid::new_v4(),
                transaction_id: proposal.transaction_id,
                cluster_id: proposal.cluster_id,
                local_node_id,
                peer_node_id: peer.node_id,
                local_address,
                peer_address,
            })
            .map_err(|error| CoordinationError::Link(error.to_string()))?;
        if !response.accepted {
            return Err(CoordinationError::Link(format!(
                "{}: {}",
                response.code, response.message
            )));
        }
        let observation: LinkObservation = serde_json::from_value(response.details)
            .map_err(|error| CoordinationError::Link(format!("invalid peer proof: {error}")))?;
        if observation.transaction_id != proposal.transaction_id
            || observation.cluster_id != proposal.cluster_id
            || observation.local_node_id != local_node_id
            || observation.peer_node_id != peer.node_id
            || observation.local_address != local_address
            || observation.peer_address != peer_address
        {
            return Err(CoordinationError::Link(
                "privileged peer proof was rebound to another transaction".into(),
            ));
        }
        Ok(ClusterLinkProof {
            version: PROPOSAL_VERSION,
            transaction_id: proposal.transaction_id,
            cluster_id: proposal.cluster_id,
            proposal_digest: proposal.digest()?,
            member_node_id: local_node_id,
            peer_node_id: peer.node_id,
            local_address,
            peer_address,
            interface: observation.interface,
            local_mac: observation.local_mac,
            neighbour_mac: observation.neighbour_mac,
            speed_mbps: observation.speed_mbps,
            mtu: observation.mtu,
            observed_at: String::new(),
            authority_signature: String::new(),
        })
    }
}

pub trait DistributedRuntimeControl: Send + Sync {
    fn start(
        &self,
        proposal: &ClusterProposal,
        local_node_id: Uuid,
        launch_id: Uuid,
        execution: &DistributedExecutionSpec,
    ) -> Result<(), CoordinationError>;

    fn healthy(
        &self,
        proposal: &ClusterProposal,
        local_node_id: Uuid,
        launch_id: Uuid,
    ) -> Result<bool, CoordinationError>;

    fn stop(&self, cluster_id: Uuid, launch_id: Uuid) -> Result<(), CoordinationError>;
}

pub struct NoDistributedRuntime;

impl DistributedRuntimeControl for NoDistributedRuntime {
    fn start(
        &self,
        _: &ClusterProposal,
        _: Uuid,
        _: Uuid,
        _: &DistributedExecutionSpec,
    ) -> Result<(), CoordinationError> {
        Err(CoordinationError::Runtime(
            "no distributed runtime backend is installed".into(),
        ))
    }

    fn healthy(&self, _: &ClusterProposal, _: Uuid, _: Uuid) -> Result<bool, CoordinationError> {
        Err(CoordinationError::Runtime(
            "no distributed runtime backend is installed".into(),
        ))
    }

    fn stop(&self, _: Uuid, _: Uuid) -> Result<(), CoordinationError> {
        Err(CoordinationError::Runtime(
            "no distributed runtime backend is installed".into(),
        ))
    }
}

#[derive(Clone)]
pub struct PrivilegedDistributedRuntime {
    client: crate::privd::PrivilegedClient,
}

impl PrivilegedDistributedRuntime {
    pub fn new(client: crate::privd::PrivilegedClient) -> Self {
        Self { client }
    }
}

impl DistributedRuntimeControl for PrivilegedDistributedRuntime {
    fn start(
        &self,
        proposal: &ClusterProposal,
        local_node_id: Uuid,
        launch_id: Uuid,
        execution: &DistributedExecutionSpec,
    ) -> Result<(), CoordinationError> {
        execution.validate(launch_id)?;
        let (local_address, peer_address) = proposal.addresses_for(local_node_id)?;
        let (coordinator_address, _) = proposal.addresses_for(proposal.coordinator_node_id)?;
        let peer_node_id = proposal
            .members
            .iter()
            .find(|member| member.node_id != local_node_id)
            .map(|member| member.node_id)
            .ok_or_else(|| CoordinationError::InvalidProposal("peer is absent".into()))?;
        let response = self
            .client
            .call(PrivilegedOperation::StartClusterLaunch {
                request_id: Uuid::new_v4(),
                transaction_id: proposal.transaction_id,
                cluster_id: proposal.cluster_id,
                launch_id,
                local_node_id,
                peer_node_id,
                coordinator_node_id: proposal.coordinator_node_id,
                local_address,
                peer_address,
                coordinator_address,
                recipe_id: execution.recipe_id.clone(),
                profile_id: execution.profile_id.clone(),
                recipe_digest: execution.recipe_digest.clone(),
                execution_digest: spark_privd::protocol::cluster_execution_digest(
                    spark_privd::protocol::ClusterExecutionDigestInput {
                        cluster_id: proposal.cluster_id,
                        launch_id,
                        local_node_id,
                        peer_node_id,
                        coordinator_node_id: proposal.coordinator_node_id,
                        recipe_id: &execution.recipe_id,
                        profile_id: &execution.profile_id,
                        recipe_digest: &execution.recipe_digest,
                        image_digest: &execution.image_digest,
                        served_name: &execution.served_name,
                        model_snapshot: &execution.model_snapshot,
                        host_port: execution.host_port,
                        gpu_memory_utilisation_milli: execution.gpu_memory_utilisation_milli,
                        max_model_length: execution.max_model_length,
                        max_sequences: execution.max_sequences,
                        max_batched_tokens: execution.max_batched_tokens,
                        tensor_parallel_size: execution.tensor_parallel_size,
                    },
                ),
                image_digest: execution.image_digest.clone(),
                served_name: execution.served_name.clone(),
                model_snapshot: execution.model_snapshot.clone(),
                host_port: execution.host_port,
                gpu_memory_utilisation_milli: execution.gpu_memory_utilisation_milli,
                max_model_length: execution.max_model_length,
                max_sequences: execution.max_sequences,
                max_batched_tokens: execution.max_batched_tokens,
                tensor_parallel_size: execution.tensor_parallel_size,
            })
            .map_err(|error| CoordinationError::Runtime(error.to_string()))?;
        if response.accepted {
            Ok(())
        } else {
            Err(CoordinationError::Runtime(format!(
                "{}: {}",
                response.code, response.message
            )))
        }
    }

    fn healthy(
        &self,
        proposal: &ClusterProposal,
        local_node_id: Uuid,
        launch_id: Uuid,
    ) -> Result<bool, CoordinationError> {
        let peer_node_id = proposal
            .members
            .iter()
            .find(|member| member.node_id != local_node_id)
            .map(|member| member.node_id)
            .ok_or_else(|| CoordinationError::InvalidProposal("peer is absent".into()))?;
        let response = self
            .client
            .call(PrivilegedOperation::ProbeClusterLaunch {
                request_id: Uuid::new_v4(),
                cluster_id: proposal.cluster_id,
                launch_id,
                local_node_id,
                peer_node_id,
            })
            .map_err(|error| CoordinationError::Runtime(error.to_string()))?;
        Ok(response.accepted && response.code == "cluster_launch_healthy")
    }

    fn stop(&self, cluster_id: Uuid, launch_id: Uuid) -> Result<(), CoordinationError> {
        let response = self
            .client
            .call(PrivilegedOperation::StopClusterLaunch {
                request_id: Uuid::new_v4(),
                cluster_id,
                launch_id,
            })
            .map_err(|error| CoordinationError::Runtime(error.to_string()))?;
        if response.accepted {
            Ok(())
        } else {
            Err(CoordinationError::Runtime(format!(
                "{}: {}",
                response.code, response.message
            )))
        }
    }
}
