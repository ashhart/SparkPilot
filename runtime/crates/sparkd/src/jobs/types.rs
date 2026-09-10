use super::*;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OperationState {
    Requested,
    Validating,
    Queued,
    Running,
    WaitingForApproval,
    Cancelling,
    Cancelled,
    Succeeded,
    Failed,
}

impl OperationState {
    pub fn as_str(self) -> &'static str {
        match self {
            OperationState::Requested => "requested",
            OperationState::Validating => "validating",
            OperationState::Queued => "queued",
            OperationState::Running => "running",
            OperationState::WaitingForApproval => "waiting_for_approval",
            OperationState::Cancelling => "cancelling",
            OperationState::Cancelled => "cancelled",
            OperationState::Succeeded => "succeeded",
            OperationState::Failed => "failed",
        }
    }

    pub fn is_terminal(self) -> bool {
        matches!(
            self,
            OperationState::Cancelled | OperationState::Succeeded | OperationState::Failed
        )
    }
}

/// Workers poll process-local cancellation flags between idempotent chunks.
#[derive(Debug, Default)]
pub struct CancellationRegistry {
    flags: HashMap<Uuid, bool>,
}

impl CancellationRegistry {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn request(&mut self, id: Uuid) {
        self.flags.insert(id, true);
    }

    pub fn is_cancelled(&self, id: &Uuid) -> bool {
        self.flags.get(id).copied().unwrap_or(false)
    }

    pub fn clear(&mut self, id: &Uuid) {
        self.flags.remove(id);
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct LeaseConfig {
    pub lease_seconds: i64,
    pub heartbeat_seconds: u64,
    /// Maximum concurrent operation workers admitted in this daemon.
    pub worker_count: usize,
}

impl Default for LeaseConfig {
    fn default() -> Self {
        Self {
            lease_seconds: 30,
            heartbeat_seconds: 10,
            worker_count: 4,
        }
    }
}
