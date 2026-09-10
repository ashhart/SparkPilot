use super::*;

impl DockerBackend {
    pub(super) fn webui_create(
        &self,
        journal: &mut Journal,
        image: &str,
        bootstrap: bool,
    ) -> Result<(), BackendError> {
        self.webui_verify(Some(journal))?;
        let volume = journal.volume.as_ref().ok_or_else(ownership_error)?;
        let mut args = self.plan_open_webui_container(image)?.argv;
        args.remove(0);
        args[0] = "create".into();
        args.retain(|arg| arg != "--detach");
        let environment = self.open_webui_root.join(if bootstrap {
            "bootstrap.env"
        } else {
            "gateway.env"
        });
        private_metadata(&environment, false)?;
        for arg in &mut args {
            if arg.starts_with("--env=PORT=") {
                *arg = format!("--env=PORT={}", journal.port);
            }
            if arg.starts_with("--volume=") {
                *arg = format!("--volume={}:/app/backend/data", volume.name);
            }
            if arg.starts_with("--env-file=") {
                *arg = format!("--env-file={}", environment.display());
            }
            if bootstrap && arg == &format!("--name={OPEN_WEBUI_CONTAINER}") {
                *arg = format!("--name={OPEN_WEBUI_BOOTSTRAP_CONTAINER}");
            }
            if bootstrap && arg == "--restart=unless-stopped" {
                *arg = "--restart=no".into();
            }
        }
        args.insert(1, format!("--label=spark.ownership={}", journal.generation));
        args.insert(1, "--label=spark.service=open-webui".into());
        journal.pending_create = true;
        self.webui_save(journal)?;
        let output = self.webui_command(&args.iter().map(String::as_str).collect::<Vec<_>>())?;
        let id = String::from_utf8(output)
            .map_err(|_| ownership_error())?
            .trim()
            .to_owned();
        if !valid_id(&id) {
            return Err(ownership_error());
        }
        let value = self
            .webui_inspect("container", &id)?
            .ok_or_else(ownership_error)?;
        let env = value["Config"]["Env"]
            .as_array()
            .ok_or_else(ownership_error)?;
        let mounts = value["Mounts"].as_array().ok_or_else(ownership_error)?;
        if value["Id"] != id
            || value["Config"]["Image"] != image
            || value["Config"]["Labels"]["spark.ownership"] != journal.generation.to_string()
            || value["HostConfig"]["NetworkMode"] != "host"
            || value["HostConfig"]["ReadonlyRootfs"] != true
            || value["HostConfig"]["Privileged"] != false
            || value["State"]["Running"] != false
            || !env.contains(&json!("HOST=127.0.0.1"))
            || !env.contains(&json!(format!("PORT={}", journal.port)))
            || !mounts.iter().any(|mount| {
                mount["Type"] == "volume"
                    && mount["Name"] == volume.name
                    && mount["Destination"] == "/app/backend/data"
            })
        {
            return Err(ownership_error());
        }
        journal.current = Some(Container {
            id: id.clone(),
            image: image.into(),
            configuration_sha256: hash(&configuration(&value)),
            bootstrap,
        });
        journal.pending_create = false;
        self.webui_save(journal)?;
        self.webui_command(&["start", &id])?;
        Ok(())
    }
}
