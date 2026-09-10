use super::*;

pub(super) struct WorkloadOwnership<'a> {
    pub(super) docker_bin: &'a String,
    pub(super) model_policy: model_policy::ModelPolicy<'a>,
}

impl WorkloadOwnership<'_> {
    /// Require the spark.project_id ownership label before touching a project container.
    pub(super) fn ensure_project_container(&self, container_id: &str) -> Result<(), BackendError> {
        let output = Command::new(self.docker_bin)
            .args([
                "inspect",
                "--type=container",
                "--format={{index .Config.Labels \"spark.project_id\"}}",
                container_id,
            ])
            .output()?;
        let label = String::from_utf8_lossy(&output.stdout).trim().to_owned();
        if !output.status.success() || label.is_empty() || uuid::Uuid::parse_str(&label).is_err() {
            return Err(BackendError::InvalidInput(
                "container was not created by this runtime".into(),
            ));
        }
        Ok(())
    }

    /// Require adoption policy evidence, including vLLM and its read-only model mount, before stopping an external container.
    pub(super) fn ensure_adopted_model_container(
        &self,
        workload_id: &str,
    ) -> Result<(), BackendError> {
        let output = Command::new(self.docker_bin)
            .args([
                "inspect",
                "--type=container",
                "--format={{json .Config.Entrypoint}}\t{{json .Mounts}}",
                workload_id,
            ])
            .output()?;
        if !output.status.success() || output.stdout.len() > crate::adoption::MAX_INSPECT_BYTES {
            return Err(BackendError::Failure(
                "the adopted container could not be inspected".into(),
            ));
        }
        let text = String::from_utf8_lossy(&output.stdout);
        let Some((entrypoint_json, mounts_json)) = text.trim().split_once('\t') else {
            return Err(BackendError::Failure(
                "the adopted container inspection had an unsupported shape".into(),
            ));
        };
        let entrypoint: Vec<String> = serde_json::from_str(entrypoint_json).unwrap_or_default();
        #[derive(serde::Deserialize)]
        #[serde(rename_all = "PascalCase")]
        struct Mount {
            #[serde(default)]
            destination: String,
            #[serde(default)]
            rw: bool,
        }
        let mounts: Vec<Mount> = serde_json::from_str(mounts_json).unwrap_or_default();
        let model_mount = mounts
            .iter()
            .any(|mount| mount.destination == "/model" && !mount.rw);
        if entrypoint != ["vllm"] || !model_mount {
            return Err(BackendError::InvalidInput(
                "container is not an adopted model workload".into(),
            ));
        }
        Ok(())
    }

    pub(super) fn inspect_model_adoption(
        &self,
        policy: &crate::adoption::ModelAdoptionPolicy,
    ) -> Result<crate::adoption::AdoptionInspection, BackendError> {
        if !crate::adoption::valid_workload_id(&policy.workload_id)
            || !valid_recipe_id(&policy.recipe_id)
            || !valid_profile_id(&policy.profile_id)
            || !valid_pinned_image(&policy.image_digest)
            || !valid_served_name(&policy.served_name)
            || policy.allow_network_during_inference
        {
            return Err(BackendError::InvalidInput(
                "model adoption policy is outside the supported isolated vLLM profile".into(),
            ));
        }
        self.model_policy
            .validate_model_snapshot(&policy.model_snapshot)?;
        let container = Command::new(self.docker_bin)
            .args([
                "inspect",
                "--type=container",
                "--format={{json .}}",
                &policy.workload_id,
            ])
            .output()?;
        if !container.status.success()
            || container.stdout.len() > crate::adoption::MAX_INSPECT_BYTES
        {
            return Err(BackendError::Failure(
                "the external container could not be inspected".into(),
            ));
        }
        let image = Command::new(self.docker_bin)
            .args([
                "image",
                "inspect",
                "--format={{json .Config.Env}}",
                &policy.image_digest,
            ])
            .output()?;
        if !image.status.success() || image.stdout.len() > crate::adoption::MAX_INSPECT_BYTES {
            return Err(BackendError::Failure(
                "the immutable image defaults could not be inspected".into(),
            ));
        }
        crate::adoption::inspect(&container.stdout, &image.stdout, policy)
            .map_err(BackendError::Failure)
    }
}
