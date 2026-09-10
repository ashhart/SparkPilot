use super::*;

/// Probe physical QSFP links through typed privileged operations or injected test evidence.
pub trait LinkProbing: Send + Sync {
    /// Discover ConnectX, require carrier and return the validated report.
    fn probe(&self) -> Result<LinkReport, ClusterError>;

    /// Refuse cluster formation without a real fabric backend capable of proving link evidence.
    fn backend_installed(&self) -> bool {
        true
    }
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct LinkReport {
    pub interface: String,
    pub link_up: bool,
    pub mtu: u32,
    pub bandwidth_gbitps_ok: bool,
}

/// Gate ready state on the pinned NCCL/Ray collective test through the privileged backend.
pub trait CollectiveTesting: Send + Sync {
    fn run(&self) -> Result<CollectiveOutcome, ClusterError>;
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CollectiveOutcome {
    Passed,
    Failed,
    /// Not exercised in this build (no hardware backend installed).
    Skipped,
}

/// Test doubles never replace production probes; NoLinkProbe refuses rather than fabricating success.
pub struct NoLinkProbe;

pub struct NoCollectiveTest;

impl LinkProbing for NoLinkProbe {
    fn probe(&self) -> Result<LinkReport, ClusterError> {
        Err(ClusterError::LinkUnhealthy(
            "no cluster-link backend is installed on this build".into(),
        ))
    }

    fn backend_installed(&self) -> bool {
        false
    }
}

impl CollectiveTesting for NoCollectiveTest {
    fn run(&self) -> Result<CollectiveOutcome, ClusterError> {
        Ok(CollectiveOutcome::Skipped)
    }
}

/// Build a pure two-node launch plan using recipe-controlled topology.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct DistributedLaunchPlan {
    pub model_path: String,
    pub tensor_parallel_size: u32,
    pub distributed_executor_backend: String,
    pub max_model_len: u64,
    pub max_num_seqs: u32,
}

impl DistributedLaunchPlan {
    /// Construct distributed invocation arguments without shell text.
    pub fn for_two_nodes(model_path: &str, max_model_len: u64, max_num_seqs: u32) -> Self {
        Self {
            model_path: model_path.to_owned(),
            tensor_parallel_size: 2,
            distributed_executor_backend: "ray".into(),
            max_model_len,
            max_num_seqs,
        }
    }

    /// Preserve tensor-parallel size two with the Ray distributed executor.
    pub fn arguments(&self) -> Vec<String> {
        vec![
            "serve".into(),
            self.model_path.clone(),
            "--tensor-parallel-size".into(),
            self.tensor_parallel_size.to_string(),
            "--distributed-executor-backend".into(),
            self.distributed_executor_backend.clone(),
            "--max-model-len".into(),
            self.max_model_len.to_string(),
            "--max-num-seqs".into(),
            self.max_num_seqs.to_string(),
        ]
    }
}
