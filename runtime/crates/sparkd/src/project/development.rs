use super::*;
use rusqlite::OptionalExtension;

use spark_core::DEVELOPMENT_IMAGE;

impl ProjectManager {
    /// Resolve the persisted checkout, never the protected sources or an arbitrary client path.
    pub fn development_workspace(&self, project: &ProjectView) -> Result<ProjectView, String> {
        let row: Option<String> = self
            .db
            .lock()
            .query_row(
                "SELECT w.branch_name FROM development_workspaces d JOIN project_worktrees w
             ON w.id = d.worktree_id WHERE d.project_id = ?1 AND w.project_id = ?1
             AND w.state != 'deleted'",
                [project.id.to_string()],
                |row| row.get(0),
            )
            .optional()
            .map_err(|e| e.to_string())?;
        let branch = row.ok_or("DEVELOPMENT_WORKSPACE_NOT_FOUND")?;
        let mut view = project.clone();
        view.root_path = self.worktree_path_for_branch(&branch)?;
        Ok(view)
    }

    /// Persist checkout identity before launching, so a failed install/restart reuses the same files.
    pub fn ensure_development_workspace(
        &self,
        project: &ProjectView,
    ) -> Result<RunningContainer, String> {
        let lock = self.project_locks.lock_for(project.id);
        let _guard = lock.lock();
        self.get(&project.id)?;
        let plan = spark_project_runner::parse_devcontainer(&format!(
            r#"{{"image":"{DEVELOPMENT_IMAGE}"}}"#
        ))
        .map_err(|e| e.to_string())?;
        let existing = self.development_workspace(project);
        let path = match existing {
            Ok(workspace) => workspace.root_path,
            Err(error) if error == "DEVELOPMENT_WORKSPACE_NOT_FOUND" => {
                // Create the isolated clone without starting a container until its identity is durable.
                let worktrees = self.worktrees();
                let created = worktrees.create_worktree_using_plan(
                    project,
                    None,
                    None,
                    Some(plan.clone()),
                    false,
                )?;
                self.db.lock().execute(
                    "INSERT INTO development_workspaces (project_id, worktree_id, image_digest, created_at)
                     VALUES (?1, ?2, ?3, strftime('%Y-%m-%dT%H:%M:%fZ','now'))",
                    rusqlite::params![project.id.to_string(), created.id.to_string(), DEVELOPMENT_IMAGE]
                ).map_err(|e| e.to_string())?;
                if let Some(container) = created.container {
                    return Ok(container);
                }
                created.path
            }
            Err(error) => return Err(error),
        };
        // Installation caches, per-session gateways and provider sign-in must never become Git content.
        crate::beneath::create_dir_all_beneath(&path, ".git/info")
            .map_err(|error| format!("Workspace Git exclusions could not be prepared: {error}"))?;
        let exclusions =
            match crate::beneath::read_beneath_bounded(&path, ".git/info/exclude", 131_072) {
                Ok(bytes) => bytes,
                Err(crate::beneath::BeneathError::NotFound(_)) => Vec::new(),
                Err(error) => {
                    return Err(format!(
                        "Workspace Git exclusions could not be read: {error}"
                    ));
                }
            };
        let mut exclusions =
            String::from_utf8(exclusions).map_err(|_| "Workspace Git exclusions are not UTF-8")?;
        if !exclusions.lines().any(|line| line == "/.spark-*")
            || !exclusions.lines().any(|line| line == "/.g-*")
        {
            exclusions
                .push_str("\n# Spark Pilot workspace state and credentials\n/.spark-*\n/.g-*\n");
            crate::beneath::write_beneath(&path, ".git/info/exclude", exclusions.as_bytes())
                .map_err(|error| format!("Workspace Git exclusions could not be saved: {error}"))?;
        }
        self.containers
            .start(&plan, project.id, &path)
            .map_err(|e| e.to_string())
    }

    #[allow(clippy::too_many_arguments)]
    pub fn development_terminal_create(
        &self,
        id: Uuid,
        project_id: Uuid,
        creator: Uuid,
        columns: u16,
        rows: u16,
        container: RunningContainer,
    ) -> Result<TerminalRecord, String> {
        let lock = self.project_locks.lock_for(project_id);
        let _guard = lock.lock();
        self.get(&project_id)?;
        self.terminals.terminal_create_in(
            id,
            project_id,
            creator,
            spark_project_runner::TerminalShell::Development,
            columns,
            rows,
            container,
        )
    }
}
