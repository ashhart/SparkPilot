//! Keep agent edits in isolated worktrees and run project containers unprivileged without the host Docker socket.

pub mod container;
pub mod devcontainer;
mod git_snapshot;
pub mod pty;
pub mod worktree;

pub use container::{ContainerBoundary, FakeContainerBoundary, RunningContainer};
pub use devcontainer::{
    DevcontainerError, DevcontainerPlan, load_plan, parse as parse_devcontainer,
};
#[cfg(feature = "host-pty")]
pub use pty::NativePtyRunner;
pub use pty::{
    FdPtySession, PtyError, PtyRunner, PtySession, PtySpawnRequest, ScriptedPtyRunner,
    TerminalShell,
};
pub use worktree::{
    CommandGit, GIT_OUTPUT_CAP, GitRunner, WorktreeError, agent_branch_name, create_agent_worktree,
    ensure_main_checkout, remove_worktree, safe_worktree_path, squash_merge, status_porcelain,
    worktree_list,
};
