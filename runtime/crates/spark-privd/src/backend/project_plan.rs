use super::*;

pub(super) struct ProjectPlan<'a> {
    pub(super) docker_bin: &'a String,
    pub(super) worktrees_root: &'a Path,
    pub(super) service_uid: u32,
    pub(super) service_gid: u32,
    pub(super) plan_only: bool,
}

impl ProjectPlan<'_> {
    /// Build project arguments on the ordinary bridge, isolated from inference-only networking and host-loopback engines.
    pub(super) fn plan_start_project_container(
        &self,
        operation: &PrivilegedOperation,
    ) -> Result<ProjectContainerPlan, BackendError> {
        let PrivilegedOperation::StartProjectContainer {
            project_id,
            worktree_id,
            image_digest,
            workspace_host_path,
            forward_ports,
            ..
        } = operation
        else {
            return Err(BackendError::InvalidInput(
                "project container launch plan requires start_project_container".into(),
            ));
        };
        if !valid_pinned_image(image_digest) {
            return Err(BackendError::InvalidInput(
                "project container image must be a pinned sha256 digest".into(),
            ));
        }
        if !(workspace_host_path.starts_with('/')
            && !workspace_host_path.contains(':')
            && !workspace_host_path.contains(' '))
        {
            return Err(BackendError::InvalidInput(format!(
                "workspace host path must be absolute without colons or spaces: {workspace_host_path}"
            )));
        }
        // The only acceptable name is the root plus the worktree's own directory; no resolution through links is offered.
        let workspace_name = format!("agent-{worktree_id}");
        if Path::new(workspace_host_path) != self.worktrees_root.join(&workspace_name) {
            return Err(BackendError::InvalidInput(
                "workspace host path must be a managed agent worktree".into(),
            ));
        }
        let workspace_pin = crate::mount_pin::PinnedDirectory::open(
            self.worktrees_root,
            Path::new(&workspace_name),
        )
        .map_err(|error| {
            BackendError::InvalidInput(format!(
                "workspace host path must be a managed agent worktree: {error}"
            ))
        })?;
        let workspace = workspace_pin.path();
        for port in forward_ports {
            // The innermost boundary refuses every runtime-owned port, not only the engine range.
            if *port == 0 || spark_core::is_runtime_owned_port(*port) {
                return Err(BackendError::InvalidInput(format!(
                    "project forward port is reserved or invalid: {port}"
                )));
            }
        }

        let container_name = format!("spark-project-{worktree_id}");
        let mut argv = vec![
            self.docker_bin.clone(),
            "run".into(),
            "--detach".into(),
            format!("--name={container_name}"),
            "--network=bridge".into(),
            "--read-only".into(),
            "--cap-drop=ALL".into(),
            "--security-opt=no-new-privileges:true".into(),
            "--pids-limit=512".into(),
            // §33.5: a project container shares the unified memory the guard defends, so it is capped.
            format!("--memory={}", spark_core::PROJECT_CONTAINER_MEMORY_BYTES),
            format!(
                "--memory-swap={}",
                spark_core::PROJECT_CONTAINER_MEMORY_BYTES
            ),
            format!("--cpus={}", spark_core::PROJECT_CONTAINER_CPUS),
            format!("--user={}:{}", self.service_uid, self.service_gid),
            format!("--label=spark.project_id={project_id}"),
            format!("--label=spark.worktree_id={worktree_id}"),
            format!("--volume={}:/workspace:rw", workspace.display()),
        ];
        if image_digest == spark_core::DEVELOPMENT_IMAGE {
            argv.push("--tmpfs=/tmp:rw,nosuid,nodev,size=536870912".into());
            argv.push("--env=HOME=/workspace/.spark-home".into());
        }
        for port in forward_ports {
            argv.push(format!("--publish=127.0.0.1:{port}:{port}"));
        }
        argv.push(image_digest.clone());
        if image_digest == spark_core::DEVELOPMENT_IMAGE {
            argv.extend(["/bin/sh", "-c", "while :; do sleep 3600; done"].map(str::to_owned));
        }

        Ok(ProjectContainerPlan {
            argv,
            workspace_pin,
            summary: serde_json::json!({
                "project_id": project_id,
                "worktree_id": worktree_id,
                "container_name": container_name,
                "network_mode": "bridge",
                "memory_limit_bytes": spark_core::PROJECT_CONTAINER_MEMORY_BYTES,
                "cpu_limit": spark_core::PROJECT_CONTAINER_CPUS,
                "host_network": false,
                "engine_network_shared": false,
            }),
        })
    }

    pub(super) fn execute_project_tool(
        &self,
        request_id: uuid::Uuid,
        project_id: &uuid::Uuid,
        container_id: &str,
        tool: &crate::protocol::ProjectToolOperation,
    ) -> Result<PrivilegedResponse, BackendError> {
        crate::project_tools::execute(
            self.docker_bin,
            self.plan_only,
            request_id,
            project_id,
            container_id,
            tool,
        )
    }
}
