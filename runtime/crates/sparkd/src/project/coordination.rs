use super::*;

#[derive(Default)]
pub(super) struct ProjectLocks {
    locks: Mutex<HashMap<Uuid, Arc<Mutex<()>>>>,
}

impl ProjectLocks {
    pub(super) fn lock_for(&self, project_id: Uuid) -> Arc<Mutex<()>> {
        self.locks
            .lock()
            .entry(project_id)
            .or_insert_with(|| Arc::new(Mutex::new(())))
            .clone()
    }
}

/// Preview ports keyed by project and by the container that published them, so they leave with that container.
#[derive(Default)]
pub(super) struct PreviewPorts {
    ports: Mutex<HashMap<Uuid, Vec<(u16, String)>>>,
}

impl PreviewPorts {
    /// Exclude every runtime-owned loopback port from the preview registry, as required by ADR-006.
    pub fn register_preview_port(&self, project_id: &Uuid, port: u16, container_id: &str) {
        if spark_core::is_runtime_owned_port(port) {
            tracing::warn!(
                project_id = %project_id,
                port,
                "refused to register a runtime-owned port for preview"
            );
            return;
        }
        self.ports
            .lock()
            .entry(*project_id)
            .or_default()
            .push((port, container_id.to_owned()));
    }

    pub fn preview_port_registered(&self, project_id: &Uuid, port: u16) -> bool {
        self.ports
            .lock()
            .get(project_id)
            .is_some_and(|ports| ports.iter().any(|(candidate, _)| *candidate == port))
    }

    /// Forget a container's ports when its worktree goes, so a later service on the port is not reachable.
    pub fn unregister_container(&self, project_id: &Uuid, container_id: &str) {
        let mut ports = self.ports.lock();
        if let Some(entries) = ports.get_mut(project_id) {
            entries.retain(|(_, owner)| owner != container_id);
            if entries.is_empty() {
                ports.remove(project_id);
            }
        }
    }

    pub fn unregister_project(&self, project_id: &Uuid) {
        self.ports.lock().remove(project_id);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn runtime_owned_ports_are_never_registered() {
        let ports = PreviewPorts::default();
        let project = Uuid::new_v4();
        for port in [18080, 18081, 18082, 19443, 18100, 18199] {
            ports.register_preview_port(&project, port, "spark-project-a");
            assert!(!ports.preview_port_registered(&project, port), "{port}");
        }
        ports.register_preview_port(&project, 5173, "spark-project-a");
        assert!(ports.preview_port_registered(&project, 5173));
    }

    #[test]
    fn a_containers_ports_leave_with_it() {
        let ports = PreviewPorts::default();
        let project = Uuid::new_v4();
        ports.register_preview_port(&project, 5173, "spark-project-a");
        ports.register_preview_port(&project, 3000, "spark-project-b");
        ports.unregister_container(&project, "spark-project-a");
        assert!(!ports.preview_port_registered(&project, 5173));
        assert!(ports.preview_port_registered(&project, 3000));
        ports.unregister_project(&project);
        assert!(!ports.preview_port_registered(&project, 3000));
    }
}
