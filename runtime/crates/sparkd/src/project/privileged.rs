use super::*;

/// Delegate typed container lifecycle operations to privd without direct Docker access in sparkd.
pub struct PrivilegedContainer {
    client: crate::privd::PrivilegedClient,
}

impl PrivilegedContainer {
    pub fn new(client: crate::privd::PrivilegedClient) -> Self {
        Self { client }
    }
}

impl ContainerBoundary for PrivilegedContainer {
    fn start(
        &self,
        plan: &DevcontainerPlan,
        project_id: Uuid,
        worktree_path: &Path,
    ) -> Result<spark_project_runner::RunningContainer, String> {
        let worktree_id = worktree_path
            .file_name()
            .and_then(|name| name.to_str())
            .and_then(|name| name.strip_prefix("agent-"))
            .and_then(|id| Uuid::parse_str(id).ok())
            .ok_or_else(|| "workspace must be a managed agent-UUID checkout".to_string())?;
        let response = self
            .client
            .call(
                spark_privd::protocol::PrivilegedOperation::StartProjectContainer {
                    request_id: Uuid::new_v4(),
                    project_id,
                    worktree_id,
                    image_digest: plan.image_digest.clone(),
                    workspace_host_path: worktree_path.display().to_string(),
                    forward_ports: plan.forward_ports.clone(),
                },
            )
            .map_err(|e| format!("privileged container launch: {e}"))?;
        if !response.accepted {
            return Err(format!(
                "privileged container launch rejected: {}",
                response.message
            ));
        }
        Ok(spark_project_runner::RunningContainer {
            id: format!("spark-project-{worktree_id}"),
            project_id,
            forward_ports: plan.forward_ports.clone(),
            worktree_path: worktree_path.display().to_string(),
        })
    }

    fn stop(&self, container_id: &str) -> Result<(), String> {
        let response = self
            .client
            .call(
                spark_privd::protocol::PrivilegedOperation::StopProjectContainer {
                    request_id: Uuid::new_v4(),
                    container_id: container_id.to_owned(),
                },
            )
            .map_err(|e| format!("privileged container stop: {e}"))?;
        if !response.accepted {
            return Err(format!(
                "privileged container stop rejected: {}",
                response.message
            ));
        }
        Ok(())
    }

    fn running(&self) -> Result<Vec<String>, String> {
        Ok(Vec::new()) // absence-of-liveness is reported through stop()
    }
}

/// Receive only the PTY descriptor from fixed-argv execution inside the project container.
pub struct PrivilegedPtyRunner {
    client: crate::privd::PrivilegedClient,
}

impl PrivilegedPtyRunner {
    pub fn new(client: crate::privd::PrivilegedClient) -> Self {
        Self { client }
    }
}

impl PtyRunner for PrivilegedPtyRunner {
    fn spawn(
        &self,
        request: &spark_project_runner::PtySpawnRequest,
    ) -> Result<Box<dyn spark_project_runner::PtySession>, spark_project_runner::PtyError> {
        let (response, descriptor) = self
            .client
            .call_with_fd(
                spark_privd::protocol::PrivilegedOperation::OpenProjectTerminal {
                    request_id: Uuid::new_v4(),
                    project_id: request.project_id,
                    terminal_id: request.terminal_id,
                    container_id: request.container_id.clone(),
                    shell: request.shell,
                    columns: request.columns,
                    rows: request.rows,
                },
            )
            .map_err(|error| {
                spark_project_runner::PtyError::Spawn(format!("privileged terminal open: {error}"))
            })?;
        if !response.accepted {
            return Err(spark_project_runner::PtyError::Spawn(format!(
                "privileged terminal open rejected: {}",
                response.message
            )));
        }
        let Some(master) = descriptor else {
            // A terminal response is usable only when it includes the PTY descriptor.
            return Err(spark_project_runner::PtyError::Spawn(
                "privileged helper accepted the terminal without returning a descriptor".into(),
            ));
        };
        Ok(Box::new(spark_project_runner::FdPtySession::new(master)))
    }

    fn close(&self, terminal_id: Uuid) -> Result<(), spark_project_runner::PtyError> {
        let response = self
            .client
            .call(
                spark_privd::protocol::PrivilegedOperation::CloseProjectTerminal {
                    request_id: Uuid::new_v4(),
                    terminal_id,
                },
            )
            .map_err(|error| {
                spark_project_runner::PtyError::Spawn(format!("privileged terminal close: {error}"))
            })?;
        if !response.accepted {
            return Err(spark_project_runner::PtyError::Spawn(format!(
                "privileged terminal close rejected: {}",
                response.message
            )));
        }
        Ok(())
    }
}
