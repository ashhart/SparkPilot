use super::*;

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct ClusterLaunchStatus {
    pub launch_id: Uuid,
    pub cluster_id: Uuid,
    pub recipe_id: String,
    pub profile_id: String,
    pub state: String,
    pub coordinator_node_id: Uuid,
    pub worker_node_id: Uuid,
    pub failure_code: Option<String>,
    pub updated_at: String,
}

/// Derive executable image, model and limits from verified local recipes; public clients submit only identifiers.
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct DistributedExecutionSpec {
    pub recipe_id: String,
    pub profile_id: String,
    pub recipe_digest: String,
    pub source_revision: String,
    pub image_digest: String,
    pub served_name: String,
    pub model_snapshot: String,
    pub host_port: u16,
    pub gpu_memory_utilisation_milli: u16,
    pub max_model_length: u64,
    pub max_sequences: u32,
    pub max_batched_tokens: u64,
    pub tensor_parallel_size: u8,
}

impl DistributedExecutionSpec {
    pub fn validate(&self, launch_id: Uuid) -> Result<(), CoordinationError> {
        let expected_port = 18_100 + ((launch_id.as_u128() as u32) % 100) as u16;
        if !spark_privd::protocol::valid_recipe_id(&self.recipe_id)
            || !spark_privd::protocol::valid_profile_id(&self.profile_id)
            || self.recipe_digest.len() != 64
            || !self
                .recipe_digest
                .bytes()
                .all(|byte| byte.is_ascii_hexdigit())
            || !spark_privd::protocol::valid_pinned_image(&self.image_digest)
            || self.source_revision.len() != 40
            || !self
                .source_revision
                .bytes()
                .all(|byte| byte.is_ascii_digit() || matches!(byte, b'a'..=b'f'))
            || self.served_name.is_empty()
            || self.served_name.len() > 128
            || !self.served_name.bytes().all(|byte| {
                byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'-' | b'_' | b'/')
            })
            || !std::path::Path::new(&self.model_snapshot).is_absolute()
            || self.host_port != expected_port
            || !(400..=900).contains(&self.gpu_memory_utilisation_milli)
            || !(256..=262_144).contains(&self.max_model_length)
            || !(1..=32).contains(&self.max_sequences)
            || !(256..=1_048_576).contains(&self.max_batched_tokens)
            || self.tensor_parallel_size != 2
        {
            return Err(CoordinationError::InvalidProposal(
                "distributed execution spec fails signed recipe policy".into(),
            ));
        }
        Ok(())
    }
}

pub(super) fn launch_status_from_row(
    row: &rusqlite::Row<'_>,
) -> rusqlite::Result<ClusterLaunchStatus> {
    let parse = |index| {
        let value: String = row.get(index)?;
        Uuid::parse_str(&value).map_err(|error| {
            rusqlite::Error::FromSqlConversionFailure(
                value.len(),
                rusqlite::types::Type::Text,
                Box::new(error),
            )
        })
    };
    Ok(ClusterLaunchStatus {
        launch_id: parse(0)?,
        cluster_id: parse(1)?,
        recipe_id: row.get(2)?,
        profile_id: row.get(3)?,
        state: row.get(4)?,
        coordinator_node_id: parse(5)?,
        worker_node_id: parse(6)?,
        failure_code: row.get(7)?,
        updated_at: row.get(8)?,
    })
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ClusterPeerLoss {
    Worker,
    Coordinator,
}

impl ClusterPeerLoss {
    pub(crate) fn request_failure_code(self) -> &'static str {
        match self {
            Self::Worker => "WORKER_LOST",
            Self::Coordinator => "COORDINATOR_LOST",
        }
    }

    pub(super) fn stopped_reason(self) -> &'static str {
        match self {
            Self::Worker => "WORKER_LOST",
            Self::Coordinator => "COORDINATOR_LOST_PROMOTION_REQUIRED",
        }
    }

    pub(super) fn stop_failure_code(self) -> &'static str {
        match self {
            Self::Worker => "WORKER_LOSS_STOP_UNPROVEN",
            Self::Coordinator => "COORDINATOR_LOSS_STOP_UNPROVEN",
        }
    }

    pub(super) fn event_reason(self) -> &'static str {
        match self {
            Self::Worker => "worker_lost",
            Self::Coordinator => "coordinator_lost_promotion_required",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ClusterMonitorOutcome {
    Idle,
    Healthy,
    Degraded { consecutive_failures: u8 },
    LocalRuntimeStopped,
    DistributedWorkStopped { peer: ClusterPeerLoss },
}
