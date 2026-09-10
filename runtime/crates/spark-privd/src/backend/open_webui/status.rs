use super::*;

impl DockerBackend {
    pub(super) fn webui_managed_status(
        &self,
        request_id: uuid::Uuid,
        journal: Option<&Journal>,
    ) -> Result<PrivilegedResponse, BackendError> {
        let reply = |accepted, code: &str, details| PrivilegedResponse {
            request_id,
            accepted,
            code: code.into(),
            message: "Open WebUI service status".into(),
            details,
        };
        let current = journal.and_then(|journal| journal.current.as_ref());
        let value = current
            .map(|container| self.webui_verify_container(container))
            .transpose()?
            .flatten();
        let running = value
            .as_ref()
            .is_some_and(|value| value["State"]["Running"] == true);
        let ready = journal.is_some_and(|journal| journal.phase == Phase::Ready);
        let resumable_install = journal.is_some_and(|j| j.phase == Phase::Installing)
            && current.is_some_and(|container| !container.bootstrap);
        let healthy = ready && running && self.open_webui_healthy();
        let recovering =
            journal.is_some_and(|journal| !matches!(journal.phase, Phase::Ready | Phase::Removed));
        let gateway = TcpStream::connect_timeout(
            &SocketAddr::from(([127, 0, 0, 1], OPEN_WEBUI_GATEWAY_PORT)),
            Duration::from_millis(250),
        )
        .is_ok();
        Ok(reply(
            true,
            "open_webui_status",
            json!({"port":journal.as_ref().map_or(OPEN_WEBUI_LOOPBACK_PORT, |j| j.port),"adopted":false,"installed":value.is_some() || recovering,"running":running,"healthy":healthy,"gateway_healthy":gateway,"ownership_verified":journal.is_some(),"repair_available":((ready || resumable_install) && running && !healthy) || journal.as_ref().is_some_and(|j| matches!(j.phase, Phase::Updating | Phase::Promoting)),"image_digest":current.map(|container| &container.image),"recovery": if recovering { json!({"code":"OPEN_WEBUI_OPERATION_INTERRUPTED","action":"repair_or_remove_owned_service"}) } else { Value::Null }}),
        ))
    }
}
