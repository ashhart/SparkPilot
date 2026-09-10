use super::*;

pub const REVISION_EMPTY_HEX: &str =
    "0000000000000000000000000000000000000000000000000000000000000000";

#[derive(Debug, Clone, Serialize)]
pub struct FileEntry {
    pub path: String,
    pub revision: String,
    pub size_bytes: u64,
}

#[derive(Debug)]
pub enum FileSaveError {
    Conflict {
        current_revision: String,
        current_content: Vec<u8>,
    },
    Failure(String),
}

impl FileSaveError {
    pub fn contains(&self, needle: &str) -> bool {
        match self {
            Self::Conflict { .. } => "FILE_CONFLICT".contains(needle),
            Self::Failure(message) => message.contains(needle),
        }
    }
}

#[derive(Debug, Clone)]
pub struct ProjectView {
    pub id: Uuid,
    pub name: String,
    pub state: String,
    pub root_path: PathBuf,
    pub repository_url: Option<String>,
    pub default_branch: Option<String>,
    pub created_at: String,
    pub updated_at: String,
}

/// Omit host paths from the signed public project representation.
#[derive(Debug, Clone, Serialize)]
pub struct ProjectDto {
    pub id: Uuid,
    pub name: String,
    pub state: String,
    pub repository_url: Option<String>,
    pub default_branch: Option<String>,
    pub created_at: String,
    pub updated_at: String,
}

impl ProjectView {
    pub fn from_row(row: &store::ProjectRow) -> Self {
        Self {
            id: row.id,
            name: row.name.clone(),
            state: row.state.clone(),
            root_path: PathBuf::from(&row.root_path),
            repository_url: row.repository_url.clone(),
            default_branch: row.default_branch.clone(),
            created_at: row.created_at.clone(),
            updated_at: row.updated_at.clone(),
        }
    }

    pub fn complete(&self) -> bool {
        !self
            .root_path
            .components()
            .any(|c| matches!(c, Component::ParentDir))
    }

    pub fn dto(&self) -> ProjectDto {
        ProjectDto {
            id: self.id,
            name: self.name.clone(),
            state: self.state.clone(),
            repository_url: self.repository_url.clone(),
            default_branch: self.default_branch.clone(),
            created_at: self.created_at.clone(),
            updated_at: self.updated_at.clone(),
        }
    }
}

/// Live terminal session handle (PTY + serialised access).
pub type PtyHandle = Arc<Mutex<Box<dyn spark_project_runner::PtySession>>>;

/// Bind terminal lookup to its authorized project because a public terminal ID is not a capability.
#[derive(Clone)]
pub struct TerminalRecord {
    pub terminal_id: Uuid,
    pub project_id: Uuid,
    pub creator_device_id: Uuid,
    /// Nonempty container identity, never a host working directory.
    pub container_id: String,
    pub shell: spark_project_runner::TerminalShell,
    pub session: PtyHandle,
    pub output: Arc<super::terminal_output::TerminalOutput>,
}

/// Preserve internal lookup reasons while the API returns one non-enumerating not-found code.
#[derive(Debug, PartialEq, Eq)]
pub enum TerminalLookupError {
    NotFound,
    WrongProject,
    CloseFailed,
}

pub struct ReviewedMerge<'a> {
    pub branch: &'a str,
    pub reviewed_head: &'a str,
    pub reviewed_protected_head: &'a str,
    pub review_digest: &'a str,
    pub message: &'a str,
    pub author: &'a str,
}

/// Created agent worktree plus its (optional) dev container.
#[derive(Debug, Clone, serde::Serialize)]
pub struct CreatedWorktree {
    pub id: Uuid,
    pub path: PathBuf,
    pub branch: String,
    pub base_commit: String,
    pub container: Option<RunningContainer>,
}
