use super::*;

pub(super) struct WebUiPlan<'a> {
    pub(super) docker_bin: &'a String,
    pub(super) services_root: &'a Path,
}

impl WebUiPlan<'_> {
    pub(super) fn plan_open_webui_container(
        &self,
        image_digest: &str,
    ) -> Result<OpenWebUiContainerPlan, BackendError> {
        if !valid_open_webui_image(image_digest) {
            return Err(BackendError::InvalidInput(
                "Open WebUI image must use the allowlisted repository and a sha256 digest".into(),
            ));
        }
        let environment_path = self.services_root.join("open-webui.env");
        let argv = vec![
            self.docker_bin.clone(),
            "run".into(),
            "--detach".into(),
            "--pull=never".into(),
            format!("--name={OPEN_WEBUI_CONTAINER}"),
            "--restart=unless-stopped".into(),
            "--network=host".into(),
            "--read-only".into(),
            "--cap-drop=ALL".into(),
            "--security-opt=no-new-privileges:true".into(),
            "--pids-limit=512".into(),
            "--tmpfs=/tmp:rw,noexec,nosuid,nodev,size=268435456".into(),
            format!("--volume={OPEN_WEBUI_DATA_VOLUME}:/app/backend/data"),
            format!("--env-file={}", environment_path.display()),
            "--env=HOST=127.0.0.1".into(),
            format!("--env=PORT={OPEN_WEBUI_LOOPBACK_PORT}"),
            "--env=ENABLE_SIGNUP=False".into(),
            "--env=ENABLE_OPENAI_API=True".into(),
            "--env=ENABLE_OPENAI_API_PASSTHROUGH=False".into(),
            "--env=ENABLE_VERSION_UPDATE_CHECK=False".into(),
            "--env=ENABLE_PROFILE_IMAGE_URL_FORWARDING=False".into(),
            "--env=OFFLINE_MODE=True".into(),
            "--env=HF_HUB_OFFLINE=1".into(),
            "--env=SAFE_MODE=True".into(),
            format!("--env=OPENAI_API_BASE_URL=http://127.0.0.1:{OPEN_WEBUI_GATEWAY_PORT}/v1"),
            image_digest.into(),
        ];
        Ok(OpenWebUiContainerPlan {
            summary: serde_json::json!({
                "service_id": "open-webui",
                "container_name": OPEN_WEBUI_CONTAINER,
                "image_digest": image_digest,
                "loopback_port": OPEN_WEBUI_LOOPBACK_PORT,
                "gateway_port": OPEN_WEBUI_GATEWAY_PORT,
                "network_mode": "host",
                "loopback_only": true,
                "read_only_root": true,
                "privileged": false,
            }),
            argv,
        })
    }
}
