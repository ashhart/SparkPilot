use super::*;

pub(super) struct ClusterLaunchSpec<'a> {
    pub(super) transaction_id: uuid::Uuid,
    pub(super) cluster_id: uuid::Uuid,
    pub(super) launch_id: uuid::Uuid,
    pub(super) local_node_id: uuid::Uuid,
    pub(super) peer_node_id: uuid::Uuid,
    pub(super) coordinator_node_id: uuid::Uuid,
    pub(super) local_address: Ipv4Addr,
    pub(super) peer_address: Ipv4Addr,
    pub(super) coordinator_address: Ipv4Addr,
    pub(super) recipe_id: &'a str,
    pub(super) profile_id: &'a str,
    pub(super) recipe_digest: &'a str,
    pub(super) execution_digest: &'a str,
    pub(super) image_digest: &'a str,
    pub(super) served_name: &'a str,
    pub(super) model_snapshot_raw: &'a str,
    pub(super) model_snapshot: std::path::PathBuf,
    pub(super) host_port: u16,
    pub(super) gpu_memory_utilisation_milli: u16,
    pub(super) max_model_length: u64,
    pub(super) max_sequences: u32,
    pub(super) max_batched_tokens: u64,
    pub(super) tensor_parallel_size: u8,
}

impl<'a> ClusterLaunchSpec<'a> {
    pub(super) fn from_operation(
        backend: &DockerBackend,
        operation: &'a PrivilegedOperation,
    ) -> Result<Self, BackendError> {
        let PrivilegedOperation::StartClusterLaunch {
            transaction_id,
            cluster_id,
            launch_id,
            local_node_id,
            peer_node_id,
            coordinator_node_id,
            local_address,
            peer_address,
            coordinator_address,
            recipe_id,
            profile_id,
            recipe_digest,
            execution_digest,
            image_digest,
            served_name,
            model_snapshot,
            host_port,
            gpu_memory_utilisation_milli,
            max_model_length,
            max_sequences,
            max_batched_tokens,
            tensor_parallel_size,
            ..
        } = operation
        else {
            return Err(BackendError::InvalidInput(
                "distributed launch plan requires start_cluster_launch".into(),
            ));
        };
        let expected_port = 18_100 + ((*launch_id).as_u128() % 100) as u16;
        let has_nul = [
            recipe_id.as_str(),
            profile_id.as_str(),
            recipe_digest.as_str(),
            execution_digest.as_str(),
            image_digest.as_str(),
            served_name.as_str(),
            model_snapshot.as_str(),
        ]
        .iter()
        .any(|value| value.contains('\0'));
        if local_node_id == peer_node_id
            || !matches!(
                *coordinator_node_id,
                id if id == *local_node_id || id == *peer_node_id
            )
            || !DockerBackend::cluster_address_allowed(local_address)
            || !DockerBackend::cluster_address_allowed(peer_address)
            || !DockerBackend::cluster_address_allowed(coordinator_address)
            || local_address == peer_address
            || (*local_node_id == *coordinator_node_id && local_address != coordinator_address)
            || !valid_recipe_id(recipe_id)
            || !valid_profile_id(profile_id)
            || !valid_sha256(recipe_digest)
            || !valid_sha256(execution_digest)
            || !valid_pinned_image(image_digest)
            || !valid_served_name(served_name)
            || has_nul
            || *host_port != expected_port
            || !(400..=900).contains(gpu_memory_utilisation_milli)
            || !(256..=262_144).contains(max_model_length)
            || !(1..=32).contains(max_sequences)
            || !(256..=1_048_576).contains(max_batched_tokens)
            || *tensor_parallel_size != 2
        {
            return Err(BackendError::InvalidInput(
                "cluster launch fields fail distributed execution policy".into(),
            ));
        }
        let expected_digest = cluster_execution_digest(ClusterExecutionDigestInput {
            cluster_id: *cluster_id,
            launch_id: *launch_id,
            local_node_id: *local_node_id,
            peer_node_id: *peer_node_id,
            coordinator_node_id: *coordinator_node_id,
            recipe_id,
            profile_id,
            recipe_digest,
            image_digest,
            served_name,
            model_snapshot,
            host_port: *host_port,
            gpu_memory_utilisation_milli: *gpu_memory_utilisation_milli,
            max_model_length: *max_model_length,
            max_sequences: *max_sequences,
            max_batched_tokens: *max_batched_tokens,
            tensor_parallel_size: *tensor_parallel_size,
        });
        if execution_digest != &expected_digest {
            return Err(BackendError::InvalidInput(
                "execution digest does not match the immutable launch inputs".into(),
            ));
        }
        let model_snapshot_path = backend.validate_model_snapshot(model_snapshot)?;
        Ok(Self {
            transaction_id: *transaction_id,
            cluster_id: *cluster_id,
            launch_id: *launch_id,
            local_node_id: *local_node_id,
            peer_node_id: *peer_node_id,
            coordinator_node_id: *coordinator_node_id,
            local_address: *local_address,
            peer_address: *peer_address,
            coordinator_address: *coordinator_address,
            recipe_id,
            profile_id,
            recipe_digest,
            execution_digest,
            image_digest,
            served_name,
            model_snapshot_raw: model_snapshot,
            model_snapshot: model_snapshot_path,
            host_port: *host_port,
            gpu_memory_utilisation_milli: *gpu_memory_utilisation_milli,
            max_model_length: *max_model_length,
            max_sequences: *max_sequences,
            max_batched_tokens: *max_batched_tokens,
            tensor_parallel_size: *tensor_parallel_size,
        })
    }

    pub(super) fn is_coordinator(&self) -> bool {
        self.local_node_id == self.coordinator_node_id
    }
}

pub(in super::super) fn validate_start_operation(
    backend: &DockerBackend,
    operation: &PrivilegedOperation,
) -> Result<(), BackendError> {
    ClusterLaunchSpec::from_operation(backend, operation).map(|_| ())
}
