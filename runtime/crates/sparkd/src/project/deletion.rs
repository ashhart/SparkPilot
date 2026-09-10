use super::*;

impl ProjectManager {
    pub(crate) fn set_build_work_dir(&self, path: PathBuf) {
        *self.build_work_dir.lock() = Some(path);
    }

    /// Remove only registered, contained project data; retain the row if any cleanup fails.
    pub fn delete_project(&self, operation_id: Uuid, project_id: &Uuid) -> Result<(), String> {
        let lock = self.project_locks.lock_for(*project_id);
        let _guard = lock.lock();
        let row = store::project_row(&self.db.lock(), project_id)
            .map_err(|e| e.to_string())?
            .ok_or("PROJECT_NOT_FOUND")?;
        let root = PathBuf::from(&row.root_path);
        validate_directory(&self.projects_root, &root)?;
        let (worktrees, builds) = {
            let conn = self.db.lock();
            let worktrees = paths(
                &conn,
                "SELECT path FROM project_worktrees WHERE project_id = ?1",
                project_id,
            )?;
            let builds = paths(
                &conn,
                "SELECT id FROM builds WHERE project_id = ?1",
                project_id,
            )?;
            (worktrees, builds)
        };
        let mut containers = Vec::new();
        for path in &worktrees {
            let path = Path::new(path);
            validate_directory(&self.worktrees_root, path)?;
            let id = path
                .file_name()
                .and_then(|n| n.to_str())
                .and_then(|n| n.strip_prefix("agent-"))
                .and_then(|n| Uuid::parse_str(n).ok())
                .ok_or("PROJECT_PATH_INVALID")?;
            containers.push(format!("spark-project-{id}"));
        }
        let build_root = self
            .build_work_dir
            .lock()
            .as_ref()
            .map(|p| p.join("builds"));
        let mut build_paths = Vec::new();
        for build in builds {
            let id = Uuid::parse_str(&build).map_err(|_| "PROJECT_PATH_INVALID")?;
            let parent = build_root.as_ref().ok_or("BUILD_STORAGE_UNAVAILABLE")?;
            let path = parent.join(id.to_string());
            validate_directory(parent, &path)?;
            build_paths.push(path);
        }
        // A preparing harness still owns its checkout; wait for preparation rather than racing it.
        if self.terminals.has_pending(project_id) {
            return Err("PROJECT_BUSY".into());
        }
        {
            let conn = self.db.lock();
            let busy: bool = conn
                .query_row(
                    "SELECT EXISTS(SELECT 1 FROM operations WHERE id != ?2
                 AND json_extract(input_json, '$.project_id') = ?1
                 AND state NOT IN ('succeeded','failed','cancelled'))
                 OR EXISTS(SELECT 1 FROM builds WHERE project_id = ?1
                 AND status NOT IN ('completed','failed','cancelled'))",
                    rusqlite::params![project_id.to_string(), operation_id.to_string()],
                    |r| r.get(0),
                )
                .map_err(|e| e.to_string())?;
            if busy {
                return Err("PROJECT_BUSY".into());
            }
            store::update_project_state(&conn, project_id, "deleting")
                .map_err(|e| e.to_string())?;
        }
        for terminal in self.terminals.terminals_for_project(project_id) {
            self.terminals
                .terminal_close(project_id, &terminal)
                .map_err(|_| "PROJECT_TERMINAL_CLOSE_FAILED")?;
        }
        for container in containers {
            self.containers.stop(&container)?;
        }
        for path in worktrees {
            remove_directory(Path::new(&path))?;
        }
        for path in build_paths {
            remove_directory(&path)?;
        }
        remove_directory(&root)?;
        self.preview_ports.unregister_project(project_id);
        self.terminals.forget_project(project_id);
        let mut conn = self.db.lock();
        let transaction = conn.transaction().map_err(|e| e.to_string())?;
        transaction
            .execute(
                "DELETE FROM builds WHERE project_id = ?1",
                [project_id.to_string()],
            )
            .map_err(|e| e.to_string())?;
        store::remove_project_row(&transaction, project_id).map_err(|e| e.to_string())?;
        transaction.commit().map_err(|e| e.to_string())?;
        self.events.emit_scoped(
            Some(&conn),
            &self.node_id,
            Some(operation_id),
            "project.deleted",
            "info",
            serde_json::json!({ "project_id": project_id }),
            crate::events::Visibility::project(*project_id),
        );
        Ok(())
    }
}

fn paths(conn: &rusqlite::Connection, sql: &str, project: &Uuid) -> Result<Vec<String>, String> {
    conn.prepare(sql)
        .map_err(|e| e.to_string())?
        .query_map([project.to_string()], |r| r.get(0))
        .map_err(|e| e.to_string())?
        .collect::<Result<Vec<_>, _>>()
        .map_err(|e| e.to_string())
}

fn validate_directory(parent: &Path, path: &Path) -> Result<(), String> {
    // Only immediate children of the configured root are valid; do not follow a substituted link.
    if path.parent() != Some(parent) || path.file_name().is_none() {
        return Err("PROJECT_PATH_INVALID".into());
    }
    match std::fs::symlink_metadata(path) {
        Ok(metadata) if metadata.file_type().is_dir() => {
            let actual = path.canonicalize().map_err(|e| e.to_string())?;
            let parent = parent.canonicalize().map_err(|e| e.to_string())?;
            if actual.parent() != Some(parent.as_path()) {
                return Err("PROJECT_PATH_INVALID".into());
            }
            Ok(())
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        _ => Err("PROJECT_PATH_INVALID".into()),
    }
}

fn remove_directory(path: &Path) -> Result<(), String> {
    match std::fs::remove_dir_all(path) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(format!("PROJECT_DELETE_FAILED: {error}")),
    }
}
