use super::*;

pub(super) struct InferenceNetwork<'a> {
    pub(super) docker_bin: &'a String,
    pub(super) backend: &'a DockerBackend,
}

impl InferenceNetwork<'_> {
    pub(super) fn ensure_inference_isolated_network(&self) -> Result<(), BackendError> {
        if self.inference_network_inspect()?.is_none() {
            let output = Command::new(self.docker_bin)
                .args([
                    "network",
                    "create",
                    "--driver=bridge",
                    // Disable masquerading for isolation while retaining a gateway for loopback publication; see docs/development/privileged-boundaries.md.
                    "--opt=com.docker.network.bridge.enable_ip_masquerade=false",
                    "--opt=com.docker.network.bridge.enable_icc=false",
                    "--opt=com.docker.network.bridge.host_binding_ipv4=127.0.0.1",
                    INFERENCE_ISOLATED_NETWORK,
                ])
                .output()?;
            if !output.status.success() {
                let message = String::from_utf8_lossy(&output.stderr);
                if !message.to_ascii_lowercase().contains("already exists") {
                    return Err(BackendError::Failure(format!(
                        "could not create the inference isolation network: {}",
                        message.trim()
                    )));
                }
            }
        }
        let network = self.inference_network_inspect()?.ok_or_else(|| {
            BackendError::Failure(
                "inference isolation network was not retained after creation".into(),
            )
        })?;
        if validate_inference_network(&network).is_err() {
            // Replace incompatible networks; Docker refuses removal while containers remain attached.
            let removed = Command::new(self.docker_bin)
                .args(["network", "rm", INFERENCE_ISOLATED_NETWORK])
                .output()?;
            if !removed.status.success() {
                return Err(BackendError::Failure(format!(
                    "the inference isolation network does not satisfy the fixed policy and \
                     could not be replaced: {}",
                    String::from_utf8_lossy(&removed.stderr).trim()
                )));
            }
            return self.ensure_inference_isolated_network();
        }
        inference_firewall::ensure(self.backend, &network)
    }

    pub(super) fn inference_network_inspect(
        &self,
    ) -> Result<Option<serde_json::Value>, BackendError> {
        let output = Command::new(self.docker_bin)
            .args(["network", "inspect", INFERENCE_ISOLATED_NETWORK])
            .output()?;
        if !output.status.success() {
            let message = String::from_utf8_lossy(&output.stderr);
            let lower = message.to_ascii_lowercase();
            if lower.contains("no such network") || lower.contains("not found") {
                return Ok(None);
            }
            return Err(BackendError::Failure(format!(
                "could not inspect the inference isolation network: {}",
                message.trim()
            )));
        }
        let networks: Vec<serde_json::Value> =
            serde_json::from_slice(&output.stdout).map_err(|error| {
                BackendError::Failure(format!(
                    "container runtime returned malformed inference network state: {error}"
                ))
            })?;
        if networks.len() != 1 {
            return Err(BackendError::Failure(
                "container runtime returned an ambiguous inference network state".into(),
            ));
        }
        Ok(networks.into_iter().next())
    }
}
