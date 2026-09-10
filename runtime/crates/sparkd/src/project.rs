//! Coordinate project lifecycle through reviewed worktrees, rooted files and sandboxed terminal services.

use std::collections::HashMap;
use std::path::{Component, Path, PathBuf};
use std::sync::Arc;

use parking_lot::Mutex;
use serde::Serialize;
use sha2::Digest;
use uuid::Uuid;

use spark_project_runner::{
    ContainerBoundary, DevcontainerPlan, GitRunner, PtyRunner, RunningContainer, agent_branch_name,
    create_agent_worktree, ensure_main_checkout, remove_worktree, safe_worktree_path, squash_merge,
    status_porcelain,
};

use crate::events::EventBus;
use crate::jobs::JobService;
use crate::store;

mod coordination;
mod deletion;
mod development;
mod files;
mod privileged;
mod terminal_output;
mod terminals;
mod types;
mod worktrees;

pub use files::revision_of;
pub use privileged::{PrivilegedContainer, PrivilegedPtyRunner};
pub use types::{
    CreatedWorktree, FileEntry, FileSaveError, ProjectDto, ProjectView, PtyHandle,
    REVISION_EMPTY_HEX, ReviewedMerge, TerminalLookupError, TerminalRecord,
};

pub struct ProjectManager {
    git: Arc<dyn GitRunner>,
    containers: Arc<dyn ContainerBoundary>,
    pub db: Arc<Mutex<rusqlite::Connection>>,
    pub jobs: JobService,
    pub events: EventBus,
    node_id: String,
    projects_root: PathBuf,
    worktrees_root: PathBuf,
    project_locks: coordination::ProjectLocks,
    build_work_dir: Mutex<Option<PathBuf>>,
    /// Live terminal sessions, keyed by the compound resource identity.
    terminals: terminals::Terminals,
    /// Preview ports registered per project (loopback-only forwards).
    preview_ports: coordination::PreviewPorts,
}

impl ProjectManager {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        git: Arc<dyn GitRunner>,
        containers: Arc<dyn ContainerBoundary>,
        pty: Arc<dyn PtyRunner>,
        db: Arc<Mutex<rusqlite::Connection>>,
        jobs: JobService,
        events: EventBus,
        node_id: String,
        projects_root: PathBuf,
        worktrees_root: PathBuf,
    ) -> Self {
        Self {
            git,
            containers,
            db,
            jobs,
            events,
            node_id,
            projects_root,
            worktrees_root,
            project_locks: coordination::ProjectLocks::default(),
            build_work_dir: Mutex::new(None),
            terminals: terminals::Terminals::new(pty),
            preview_ports: coordination::PreviewPorts::default(),
        }
    }

    pub fn list(&self) -> Result<Vec<ProjectView>, String> {
        let conn = self.db.lock();
        let rows = store::project_rows(&conn, 200).map_err(|e| e.to_string())?;
        Ok(rows.iter().map(ProjectView::from_row).collect())
    }

    pub fn get(&self, project_id: &Uuid) -> Result<ProjectView, String> {
        let conn = self.db.lock();
        let row = store::project_row(&conn, project_id)
            .map_err(|e| e.to_string())?
            .ok_or_else(|| "PROJECT_NOT_FOUND".to_string())?;
        if row.state == "deleting" {
            return Err("PROJECT_DELETING".into());
        }
        Ok(ProjectView::from_row(&row))
    }

    /// Create and persist the checkout on its durable operation worker.
    pub fn create_project(
        &self,
        operation_id: Uuid,
        name: &str,
        repository_url: Option<&str>,
        revision: Option<&str>,
        owner_device_id: &Uuid,
    ) -> Result<(), String> {
        let name = name.trim();
        if name.is_empty() || name.len() > 120 {
            return Err("project name must be 1..=120 characters".into());
        }
        if !name
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.' | ' '))
        {
            return Err("project name has unsafe characters".into());
        }
        let project_id = Uuid::new_v4();
        let dir_name = format!("{}-{}", sanitize_name(name), short_id(project_id));
        let root = self.projects_root.join(&dir_name);
        std::fs::create_dir_all(&root).map_err(|e| e.to_string())?;

        ensure_main_checkout(&*self.git, &root, repository_url, revision)
            .map_err(|e| e.to_string())?;

        // A reachable HEAD is required for worktrees, so failed initial commits must abort creation.
        if self.git.run(&root, &["rev-parse", "HEAD"]).is_err() {
            self.git
                .run(&root, &["add", "-A"])
                .map_err(|error| format!("git add: {error}"))?;
            self.git
                .run(&root, &["commit", "--allow-empty", "-m", "spark: initial"])
                .map_err(|error| format!("git commit: {error}"))?;
        }

        {
            let conn = self.db.lock();
            store::insert_project(
                &conn,
                &project_id,
                name,
                owner_device_id,
                &root.display().to_string(),
                repository_url,
            )
            .map_err(|e| e.to_string())?;
            store::insert_project_member(&conn, &project_id, owner_device_id, "admin")
                .map_err(|e| e.to_string())?;
            store::update_project_state(&conn, &project_id, "ready").map_err(|e| e.to_string())?;
        }
        let conn = self.db.lock();
        self.events.emit_scoped(
            Some(&conn),
            &self.node_id,
            Some(operation_id),
            "project.created",
            "info",
            serde_json::json!({ "project_id": project_id, "name": name }),
            crate::events::Visibility::project(project_id),
        );
        Ok(())
    }

    /// Enforce revision preconditions through beneath-root, no-follow filesystem operations.
    pub fn file_save(
        &self,
        project: &ProjectView,
        relative: &str,
        bytes: &[u8],
        if_match: &str,
    ) -> Result<String, FileSaveError> {
        self.files().file_save(project, relative, bytes, if_match)
    }

    pub fn file_read(&self, project: &ProjectView, relative: &str) -> Result<Vec<u8>, String> {
        self.files().file_read(project, relative)
    }

    pub fn file_list(&self, project: &ProjectView) -> Result<Vec<FileEntry>, String> {
        self.files().file_list(project)
    }

    /// Load the validated dev-container plan for a project (if any).
    pub fn devcontainer_plan(
        &self,
        project: &ProjectView,
    ) -> Result<Option<DevcontainerPlan>, String> {
        self.worktrees().devcontainer_plan(project)
    }

    /// Create an agent worktree and validated container, binding any supplied durable operation ID.
    pub fn create_worktree(
        &self,
        project: &ProjectView,
        base_commit: Option<&str>,
        operation_id: Option<Uuid>,
    ) -> Result<CreatedWorktree, String> {
        let lock = self.project_locks.lock_for(project.id);
        let _guard = lock.lock();
        self.get(&project.id)?;
        self.worktrees()
            .create_worktree(project, base_commit, operation_id)
    }

    pub fn commit_at(&self, checkout: &Path) -> Result<String, String> {
        self.worktrees().commit_at(checkout)
    }

    pub fn protected_head(&self, project: &ProjectView) -> Result<String, String> {
        self.worktrees().protected_head(project)
    }

    pub fn status_at(&self, checkout: &Path) -> Result<String, String> {
        self.worktrees().status_at(checkout)
    }

    pub fn is_ancestor(&self, checkout: &Path, base: &str, head: &str) -> Result<bool, String> {
        self.worktrees().is_ancestor(checkout, base, head)
    }

    pub fn diff_name_status(
        &self,
        checkout: &Path,
        base: &str,
        head: &str,
    ) -> Result<String, String> {
        self.worktrees().diff_name_status(checkout, base, head)
    }

    pub fn diff_numstat(&self, checkout: &Path, base: &str, head: &str) -> Result<String, String> {
        self.worktrees().diff_numstat(checkout, base, head)
    }

    pub fn diff_patch(&self, checkout: &Path, base: &str, head: &str) -> Result<String, String> {
        self.worktrees().diff_patch(checkout, base, head)
    }

    pub fn worktree_path_for_branch(&self, branch: &str) -> Result<PathBuf, String> {
        self.worktrees().worktree_path_for_branch(branch)
    }

    /// Merge exact reviewed heads and reconcile an applied retry without creating another commit.
    pub fn merge_reviewed_worktree(
        &self,
        project: &ProjectView,
        review: &ReviewedMerge<'_>,
    ) -> Result<String, String> {
        self.worktrees().merge_reviewed_worktree(project, review)
    }

    pub fn worktree_list(&self, project: &ProjectView) -> Result<Vec<String>, String> {
        self.worktrees().worktree_list(project)
    }

    pub fn worktree_status(&self, project: &ProjectView) -> Result<String, String> {
        self.worktrees().worktree_status(project)
    }

    pub fn merge_worktree(
        &self,
        project: &ProjectView,
        branch: &str,
        message: &str,
        author: &str,
    ) -> Result<(), String> {
        self.worktrees()
            .merge_worktree(project, branch, message, author)
    }

    pub fn remove_worktree(&self, project: &ProjectView, path: &Path) -> Result<(), String> {
        self.worktrees().remove_worktree(project, path)
    }

    /// Require a validated project container; absence of a sandbox must never fall back to a host process.
    pub fn ensure_project_container(
        &self,
        project: &ProjectView,
    ) -> Result<RunningContainer, String> {
        let lock = self.project_locks.lock_for(project.id);
        let _guard = lock.lock();
        self.terminals
            .ensure_project_container(project, &self.worktrees())
    }

    /// Reuse an already-running worktree container as the project terminal sandbox.
    pub fn adopt_project_container(&self, project_id: Uuid, container: RunningContainer) {
        self.terminals
            .adopt_project_container(project_id, container)
    }

    /// Use the HTTP-assigned session identity for both durable records and the privileged PTY.
    pub fn mark_terminal_failed(&self, project_id: Uuid, terminal_id: Uuid, message: String) {
        self.terminals.mark_failed(project_id, terminal_id, message);
    }
    pub fn terminal_failure(&self, project_id: &Uuid, terminal_id: &Uuid) -> Option<String> {
        self.terminals.failure(project_id, terminal_id)
    }

    pub fn reserve_terminal(
        &self,
        project_id: Uuid,
        terminal_id: Uuid,
    ) -> Result<terminals::PendingTerminal, String> {
        let lock = self.project_locks.lock_for(project_id);
        let _guard = lock.lock();
        self.get(&project_id)?;
        self.terminals.reserve(project_id, terminal_id)
    }

    pub fn terminal_state(&self, project_id: &Uuid, terminal_id: &Uuid) -> Option<&'static str> {
        self.terminals.state(project_id, terminal_id)
    }

    pub fn terminal_create(
        &self,
        id: Uuid,
        project: &ProjectView,
        creator_device_id: Uuid,
        shell: spark_project_runner::TerminalShell,
        columns: u16,
        rows: u16,
    ) -> Result<TerminalRecord, String> {
        self.terminals.terminal_create(
            id,
            project,
            creator_device_id,
            shell,
            columns,
            rows,
            &self.worktrees(),
        )
    }

    /// Resolve terminals only through the compound identity of session and authorized project.
    pub fn terminal(
        &self,
        project_id: &Uuid,
        terminal_id: &Uuid,
    ) -> Result<TerminalRecord, TerminalLookupError> {
        self.terminals.terminal(project_id, terminal_id)
    }

    /// Close the descriptor and privileged child under the same compound session identity.
    pub fn terminal_close(
        &self,
        project_id: &Uuid,
        terminal_id: &Uuid,
    ) -> Result<(), TerminalLookupError> {
        self.terminals.terminal_close(project_id, terminal_id)
    }

    /// Live sessions for a project (diagnostics and tests).
    pub fn terminals_for_project(&self, project_id: &Uuid) -> Vec<Uuid> {
        self.terminals.terminals_for_project(project_id)
    }

    /// Exclude runtime-owned ports from the loopback preview registry, as required by ADR-006.
    pub fn register_preview_port(&self, project_id: &Uuid, port: u16, container_id: &str) {
        self.preview_ports
            .register_preview_port(project_id, port, container_id)
    }

    pub fn unregister_preview_container(&self, project_id: &Uuid, container_id: &str) {
        self.preview_ports
            .unregister_container(project_id, container_id)
    }

    pub fn preview_port_registered(&self, project_id: &Uuid, port: u16) -> bool {
        self.preview_ports.preview_port_registered(project_id, port)
    }

    fn files(&self) -> files::Files<'_> {
        files::Files {
            locks: &self.project_locks,
        }
    }

    fn worktrees(&self) -> worktrees::Worktrees<'_> {
        worktrees::Worktrees {
            git: &*self.git,
            containers: &*self.containers,
            db: &self.db,
            worktrees_root: &self.worktrees_root,
            locks: &self.project_locks,
            previews: &self.preview_ports,
        }
    }
}

fn short_id(id: Uuid) -> String {
    id.simple().to_string()[..8].to_owned()
}

fn sanitize_name(name: &str) -> String {
    name.chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.') {
                c
            } else {
                '_'
            }
        })
        .collect()
}
