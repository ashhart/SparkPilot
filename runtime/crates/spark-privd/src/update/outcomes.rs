use super::*;

/// Outcome of one `InstallRuntimeUpdate` transaction.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum UpdateOutcome {
    /// Detached worker queued without package-manager work in the request handler.
    Scheduled { release_id: String },
    /// Release applied, health verified and commit recorded.
    Committed { release_id: String, sha256: String },
    /// The release is already the current commit; retrying is a no-op.
    AlreadyCommitted { release_id: String },
    /// Installation failed; the retained previous package was reinstalled and passed its health gate.
    RolledBack {
        release_id: String,
        rolled_back_to: String,
    },
    /// No safe package rollback exists; configuration was restored and services stopped, with evidence for manual recovery.
    DataRestoredPackageManual {
        release_id: String,
        evidence: Vec<PathBuf>,
    },
}

/// Durable root-owned evidence for a detached runtime update.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(tag = "state", rename_all = "snake_case")]
pub enum RuntimeUpdateStatus {
    Scheduled { release_id: String },
    Completed { outcome: UpdateOutcome },
    Failed { release_id: String, code: String },
}

impl RuntimeUpdateStatus {
    pub fn code(&self) -> &str {
        match self {
            Self::Scheduled { .. } => "update.scheduled",
            Self::Completed { outcome } => outcome.code(),
            Self::Failed { code, .. } => code,
        }
    }

    pub fn is_terminal(&self) -> bool {
        !matches!(self, Self::Scheduled { .. })
    }
}

impl UpdateOutcome {
    pub fn code(&self) -> &'static str {
        match self {
            UpdateOutcome::Scheduled { .. } => "update.scheduled",
            UpdateOutcome::Committed { .. } => "update.committed",
            UpdateOutcome::AlreadyCommitted { .. } => "update.already_committed",
            UpdateOutcome::RolledBack { .. } => "update.rolled_back",
            UpdateOutcome::DataRestoredPackageManual { .. } => {
                "update.data_restored_package_manual"
            }
        }
    }

    /// False means manual recovery left the node stopped without applying the update or rolling back its package.
    pub fn accepted(&self) -> bool {
        !matches!(self, UpdateOutcome::DataRestoredPackageManual { .. })
    }
}

#[derive(Debug, Error)]
pub enum UpdateError {
    #[error("I/O error: {0}")]
    Io(#[from] std::io::Error),
    #[error("{0}")]
    Failure(String),
    #[error("{0}")]
    Refused(String),
}

impl From<String> for UpdateError {
    fn from(message: String) -> Self {
        UpdateError::Failure(message)
    }
}

impl UpdateError {
    pub fn refused(message: impl Into<String>) -> Self {
        UpdateError::Refused(message.into())
    }
}

pub(super) fn update_failure_code(error: &UpdateError) -> String {
    error
        .to_string()
        .split_whitespace()
        .find(|part| part.starts_with("UPDATE_") && part.len() <= 96)
        .unwrap_or("RUNTIME_UPDATE_FAILED")
        .trim_end_matches(|character: char| !character.is_ascii_alphanumeric() && character != '_')
        .to_owned()
}
