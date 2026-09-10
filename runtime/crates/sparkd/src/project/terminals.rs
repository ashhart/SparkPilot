use super::*;

pub(super) struct Terminals {
    pty: Arc<dyn PtyRunner>,
    pending: Arc<Mutex<HashMap<(Uuid, Uuid), bool>>>,
    terminals: Mutex<HashMap<(Uuid, Uuid), TerminalRecord>>,
    project_containers: Mutex<HashMap<Uuid, RunningContainer>>,
    failed: Mutex<std::collections::VecDeque<((Uuid, Uuid), String)>>,
}

impl Terminals {
    pub(super) fn new(pty: Arc<dyn PtyRunner>) -> Self {
        Self {
            pty,
            pending: Arc::default(),
            terminals: Mutex::new(HashMap::new()),
            project_containers: Mutex::new(HashMap::new()),
            failed: Mutex::default(),
        }
    }

    pub(super) fn reserve(
        &self,
        project_id: Uuid,
        terminal_id: Uuid,
    ) -> Result<PendingTerminal, String> {
        let mut pending = self.pending.lock();
        if pending.len() + self.terminals.lock().len() >= 64 {
            return Err(
                "There are already 64 sessions open on this Spark; end a session and try again."
                    .into(),
            );
        }
        if pending.contains_key(&(project_id, terminal_id)) {
            return Err("This terminal is already being prepared.".into());
        }
        pending.insert((project_id, terminal_id), false);
        Ok(PendingTerminal {
            pending: self.pending.clone(),
            key: (project_id, terminal_id),
        })
    }

    pub(super) fn state(&self, project_id: &Uuid, terminal_id: &Uuid) -> Option<&'static str> {
        if let Ok(record) = self.terminal(project_id, terminal_id) {
            return Some(if record.output.is_closed() {
                "stopped"
            } else {
                "running"
            });
        }
        if let Some(cancelled) = self.pending.lock().get(&(*project_id, *terminal_id)) {
            return Some(if *cancelled { "stopped" } else { "starting" });
        }
        self.failure(project_id, terminal_id)
            .is_some()
            .then_some("failed")
    }

    pub(super) fn has_pending(&self, project: &Uuid) -> bool {
        self.pending.lock().keys().any(|(p, _)| p == project)
    }

    pub(super) fn forget_project(&self, project: &Uuid) {
        self.project_containers.lock().remove(project);
        self.failed.lock().retain(|((p, _), _)| p != project);
    }

    pub(super) fn mark_failed(&self, project_id: Uuid, terminal_id: Uuid, message: String) {
        let mut failed = self.failed.lock();
        failed.push_back(((project_id, terminal_id), message));
        while failed.len() > 128 {
            failed.pop_front();
        }
    }
    pub(super) fn failure(&self, project_id: &Uuid, terminal_id: &Uuid) -> Option<String> {
        self.failed
            .lock()
            .iter()
            .find(|(key, _)| *key == (*project_id, *terminal_id))
            .map(|(_, message)| message.clone())
    }

    /// Require a validated project container; absence of a sandbox must never fall back to a host process.
    pub fn ensure_project_container(
        &self,
        project: &ProjectView,
        worktrees: &worktrees::Worktrees<'_>,
    ) -> Result<RunningContainer, String> {
        let row = store::project_row(&worktrees.db.lock(), &project.id)
            .map_err(|e| e.to_string())?
            .ok_or("PROJECT_NOT_FOUND")?;
        if row.state == "deleting" {
            return Err("PROJECT_DELETING".into());
        }
        if let Some(existing) = self.project_containers.lock().get(&project.id) {
            return Ok(existing.clone());
        }
        if worktrees.devcontainer_plan(project)?.is_none() {
            return Err("PROJECT_SANDBOX_UNAVAILABLE: this project has no .devcontainer configuration, so there is no container to open a terminal in".into());
        }
        let created = worktrees
            .create_worktree(project, None, None)
            .map_err(|error| format!("PROJECT_SANDBOX_START_FAILED: {error}"))?;
        let running = created
            .container
            .ok_or_else(|| "PROJECT_SANDBOX_UNAVAILABLE: no container was prepared".to_string())?;
        for port in &running.forward_ports {
            worktrees
                .previews
                .register_preview_port(&project.id, *port, &running.id);
        }
        self.project_containers
            .lock()
            .insert(project.id, running.clone());
        Ok(running)
    }

    /// Reuse an already-running worktree container as the project terminal sandbox.
    pub fn adopt_project_container(&self, project_id: Uuid, container: RunningContainer) {
        self.project_containers.lock().insert(project_id, container);
    }

    /// Use the HTTP-assigned session identity for both durable records and the privileged PTY.
    #[allow(clippy::too_many_arguments)]
    pub fn terminal_create(
        &self,
        id: Uuid,
        project: &ProjectView,
        creator_device_id: Uuid,
        shell: spark_project_runner::TerminalShell,
        columns: u16,
        rows: u16,
        worktrees: &worktrees::Worktrees<'_>,
    ) -> Result<TerminalRecord, String> {
        let lock = worktrees.locks.lock_for(project.id);
        let _guard = lock.lock();
        let container = self.ensure_project_container(project, worktrees)?;
        self.terminal_create_in(
            id,
            project.id,
            creator_device_id,
            shell,
            columns,
            rows,
            container,
        )
    }

    #[allow(clippy::too_many_arguments)]
    pub(super) fn terminal_create_in(
        &self,
        id: Uuid,
        project_id: Uuid,
        creator_device_id: Uuid,
        shell: spark_project_runner::TerminalShell,
        columns: u16,
        rows: u16,
        container: RunningContainer,
    ) -> Result<TerminalRecord, String> {
        // Serialize the final spawn with End Session, including a launch still preparing its image.
        let pending = self.pending.lock();
        if pending.get(&(project_id, id)) == Some(&true) {
            return Err("TERMINAL_LAUNCH_CANCELLED".into());
        }
        let request = spark_project_runner::PtySpawnRequest {
            project_id,
            terminal_id: id,
            container_id: container.id.clone(),
            shell,
            columns,
            rows,
        };
        let session = self.pty.spawn(&request).map_err(|e| e.to_string())?;
        let session = Arc::new(Mutex::new(session));
        let output = super::terminal_output::TerminalOutput::start(session.clone());
        let record = TerminalRecord {
            terminal_id: id,
            project_id,
            creator_device_id,
            container_id: container.id,
            shell,
            session,
            output,
        };
        self.terminals
            .lock()
            .insert((project_id, id), record.clone());
        Ok(record)
    }

    /// Resolve terminals only through the compound identity of session and authorized project.
    pub fn terminal(
        &self,
        project_id: &Uuid,
        terminal_id: &Uuid,
    ) -> Result<TerminalRecord, TerminalLookupError> {
        let terminals = self.terminals.lock();
        if let Some(record) = terminals.get(&(*project_id, *terminal_id)) {
            return Ok(record.clone());
        }
        // Preserve cross-project evidence internally while the API returns a single refusal code.
        if terminals
            .keys()
            .any(|(_, existing)| existing == terminal_id)
        {
            return Err(TerminalLookupError::WrongProject);
        }
        Err(TerminalLookupError::NotFound)
    }

    /// Close the descriptor and privileged child under the same compound session identity.
    pub fn terminal_close(
        &self,
        project_id: &Uuid,
        terminal_id: &Uuid,
    ) -> Result<(), TerminalLookupError> {
        let mut pending = self.pending.lock();
        let cancelled_pending =
            if let Some(cancelled) = pending.get_mut(&(*project_id, *terminal_id)) {
                *cancelled = true;
                true
            } else {
                false
            };
        let removed = self.terminals.lock().remove(&(*project_id, *terminal_id));
        if removed.is_none() && cancelled_pending {
            return Ok(());
        }
        let record = removed.ok_or_else(|| match self.terminal(project_id, terminal_id) {
            Err(error) => error,
            Ok(_) => TerminalLookupError::NotFound,
        })?;
        if let Err(error) = self.pty.close(*terminal_id) {
            self.terminals
                .lock()
                .insert((*project_id, *terminal_id), record);
            tracing::warn!(%error, %terminal_id, "privileged terminal close reported an error");
            return Err(TerminalLookupError::CloseFailed);
        }
        record.output.close();
        record.session.lock().close();
        Ok(())
    }

    /// Live sessions for a project (diagnostics and tests).
    pub fn terminals_for_project(&self, project_id: &Uuid) -> Vec<Uuid> {
        self.terminals
            .lock()
            .keys()
            .filter(|(project, _)| project == project_id)
            .map(|(_, terminal)| *terminal)
            .collect()
    }
}

/// Cancelling a launch releases its reservation without leaving a false live session.
pub struct PendingTerminal {
    pending: Arc<Mutex<HashMap<(Uuid, Uuid), bool>>>,
    key: (Uuid, Uuid),
}
impl Drop for PendingTerminal {
    fn drop(&mut self) {
        self.pending.lock().remove(&self.key);
    }
}
