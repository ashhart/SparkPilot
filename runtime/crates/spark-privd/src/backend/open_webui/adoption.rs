use super::*;

pub(super) fn is_open_webui_image(image: &str) -> bool {
    image.len() <= 256
        && (image.starts_with("ghcr.io/open-webui/open-webui:")
            || image.starts_with("ghcr.io/open-webui/open-webui@sha256:"))
}

fn publishes_port(value: &Value, port: u16) -> bool {
    let image = value["Config"]["Image"].as_str().unwrap_or_default();
    if !is_open_webui_image(image) || value["State"]["Running"] != true {
        return false;
    }
    if value["HostConfig"]["NetworkMode"] == "host" {
        return value["Config"]["Env"].as_array().is_some_and(|env| {
            env.iter().any(|entry| entry == &format!("PORT={port}"))
                || (port == 8080
                    && !env
                        .iter()
                        .any(|entry| entry.as_str().is_some_and(|s| s.starts_with("PORT="))))
        });
    }
    value["NetworkSettings"]["Ports"]
        .as_object()
        .is_some_and(|ports| {
            ports
                .values()
                .filter_map(Value::as_array)
                .flatten()
                .any(|binding| {
                    binding["HostPort"]
                        .as_str()
                        .and_then(|p| p.parse::<u16>().ok())
                        == Some(port)
                        && matches!(
                            binding["HostIp"].as_str(),
                            Some("" | "0.0.0.0" | "127.0.0.1")
                        )
                })
        })
}

impl DockerBackend {
    pub(super) fn webui_adopt(
        &self,
        request_id: uuid::Uuid,
        port: u16,
    ) -> Result<PrivilegedResponse, BackendError> {
        if self
            .webui_load()?
            .is_some_and(|j| j.phase != Phase::Removed && !j.adopted)
        {
            return Err(BackendError::Failure(
                "A managed Open WebUI installation is already connected".into(),
            ));
        }
        let ids = self.webui_command(&["ps", "--no-trunc", "--format", "{{.ID}}"])?;
        let ids = std::str::from_utf8(&ids).map_err(|_| ownership_error())?;
        if ids.lines().count() > 128 {
            return Err(BackendError::Failure(
                "Too many containers to verify Open WebUI safely".into(),
            ));
        }
        let mut candidates = Vec::new();
        for id in ids.lines() {
            if !valid_id(id) {
                continue;
            }
            if let Some(value) = self.webui_inspect("container", id)?
                && publishes_port(&value, port)
            {
                candidates.push(value);
            }
        }
        if candidates.len() != 1 {
            return Err(BackendError::Failure("No unique running Open WebUI container was found on that port; check its published port".into()));
        }
        let value = &candidates[0];
        let journal = Journal {
            version: 1,
            port,
            adopted: true,
            generation: uuid::Uuid::new_v4(),
            phase: Phase::Ready,
            pending_create: false,
            volume: None,
            previous: None,
            current: Some(Container {
                id: value["Id"].as_str().ok_or_else(ownership_error)?.into(),
                image: value["Config"]["Image"]
                    .as_str()
                    .ok_or_else(ownership_error)?
                    .into(),
                configuration_sha256: hash(&configuration(value)),
                bootstrap: false,
            }),
            last_repair_epoch: 0,
            erase_data: false,
        };
        self.webui_save(&journal)?;
        Ok(PrivilegedResponse {
            request_id,
            accepted: true,
            code: "open_webui_connected".into(),
            message: "Existing Open WebUI connected; container, accounts and data are unchanged"
                .into(),
            details: json!({"adopted":true,"port":port}),
        })
    }

    pub(super) fn webui_adopted_operation(
        &self,
        operation: &PrivilegedOperation,
        journal: &mut Journal,
    ) -> Result<PrivilegedResponse, BackendError> {
        let request_id = operation.request_id();
        match operation {
            PrivilegedOperation::OpenWebUiStatus { .. } => {
                let value = journal.current.as_ref().and_then(|c| self.webui_verify_container(c).ok().flatten());
                let running = value.as_ref().is_some_and(|v| v["State"]["Running"] == true);
                Ok(PrivilegedResponse {
                    request_id, accepted:true, code:"open_webui_status".into(), message:"Existing Open WebUI connection".into(),
                    details:json!({"installed":journal.current.is_some(),"running":running,"healthy":running && self.open_webui_healthy(),"ownership_verified":value.is_some(),"adopted":true,"port":journal.port,"gateway_healthy":true,"repair_available":false}),
                })
            }
            PrivilegedOperation::RemoveOpenWebUi { erase_data: false, .. } => {
                journal.current = None;
                journal.phase = Phase::Removed;
                journal.adopted = false;
                self.webui_save(journal)?;
                Ok(PrivilegedResponse { request_id, accepted:true, code:"open_webui_disconnected".into(), message:"Connection removed; existing Open WebUI and its data are unchanged".into(), details:json!({"data_preserved":true}) })
            }
            _ => Err(BackendError::InvalidInput("Existing Open WebUI is managed outside SparkPilot; only disconnecting without data removal is allowed".into())),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn only_a_running_open_webui_at_the_selected_port_can_be_adopted() {
        let mut value = json!({"Config":{"Image":"ghcr.io/open-webui/open-webui:main"},"State":{"Running":true},"NetworkSettings":{"Ports":{"8080/tcp":[{"HostIp":"0.0.0.0","HostPort":"9090"}]}}});
        assert!(publishes_port(&value, 9090));
        assert!(!publishes_port(&value, 3000));
        value["Config"]["Image"] = json!("ghcr.io/other/service:main");
        assert!(!publishes_port(&value, 9090));
    }
}
