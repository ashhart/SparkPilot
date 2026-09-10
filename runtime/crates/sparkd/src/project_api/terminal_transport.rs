use super::*;

/// Bound interactive terminal input frames to prevent bulk-upload resource abuse.
pub(super) const MAX_TERMINAL_INPUT_BYTES: usize = 8 * 1024;

/// Retain exact attachment grants, recheck before PTY I/O and close idle attachments within one second of authorization changes.
#[derive(Clone)]
pub(super) struct TerminalAuthorization {
    pub(super) device_id: uuid::Uuid,
    pub(super) project_id: uuid::Uuid,
    pub(super) role: String,
    pub(super) permission: String,
}

impl TerminalAuthorization {
    pub(super) fn capture(
        state: &AppState,
        principal: &Principal,
        project_id: uuid::Uuid,
    ) -> Option<Self> {
        let conn = state.database.as_ref()?.lock();
        let device = crate::store::load_device_by_id(&conn, &principal.device_id).ok()??;
        if device.role != principal.role {
            return None;
        }
        let permission =
            crate::store::project_permission(&conn, &project_id, &principal.device_id).ok()??;
        crate::capability::evaluate(&crate::capability::Request {
            capability: Capability::ProjectTerminal,
            scope: crate::capability::ResourceScope::Project { project_id },
            role: crate::capability::Role::parse(&device.role),
            device_id: principal.device_id,
            project_permission: crate::capability::ProjectPermission::parse(&permission),
            presence: crate::capability::Presence::Absent,
            policy: state.capability_policy,
        })
        .ok()?;
        Some(Self {
            device_id: principal.device_id,
            project_id,
            role: device.role,
            permission,
        })
    }

    pub(super) fn is_current(&self, state: &AppState) -> bool {
        let Some(database) = state.database.as_ref() else {
            return false;
        };
        let conn = database.lock();
        let Ok(Some(device)) = crate::store::load_device_by_id(&conn, &self.device_id) else {
            return false;
        };
        device.role == self.role
            && crate::store::project_permission(&conn, &self.project_id, &self.device_id)
                .ok()
                .flatten()
                .as_deref()
                == Some(self.permission.as_str())
    }
}

pub(super) async fn drive_terminal(
    mut socket: axum::extract::ws::WebSocket,
    record: crate::project::TerminalRecord,
    state: AppState,
    authorization: TerminalAuthorization,
) {
    let session = record.session.clone();
    let mut updates = record.output.changed.subscribe();
    let mut cursor = 0;
    let mut first_resize = true;
    let mut authorization_poll = tokio::time::interval(std::time::Duration::from_secs(1));
    loop {
        if !authorization.is_current(&state) {
            break;
        }
        let (frames, closed) = record.output.snapshot(cursor);
        for (id, data) in frames {
            if !authorization.is_current(&state) {
                return;
            }
            let frame = serde_json::json!({"type":"output", "data":data}).to_string();
            if socket
                .send(axum::extract::ws::Message::Text(frame.into()))
                .await
                .is_err()
            {
                return;
            }
            cursor = id;
        }
        if closed {
            break;
        }
        tokio::select! {
            _ = authorization_poll.tick() => {
                if !authorization.is_current(&state) { break; }
            }
            frame = socket.recv() => {
                if !authorization.is_current(&state) { break; }
                match frame {
                    Some(Ok(axum::extract::ws::Message::Text(text))) => {
                        let value: serde_json::Value = match serde_json::from_str(&text) {
                            Ok(v) => v,
                            Err(_) => continue,
                        };
                        match value.get("type").and_then(Value::as_str) {
                            Some("input") => {
                                // Write input only to this session's descriptor connected to the container process.
                                if let Some(data) = value.get("data").and_then(Value::as_str) {
                                    if data.len() > MAX_TERMINAL_INPUT_BYTES {
                                        continue;
                                    }
                                    let mut guard = session.lock();
                                    if guard.write(data.as_bytes()).is_err() {
                                        break;
                                    }
                                }
                            }
                            Some("resize") => {
                                // Apply typed window size to the master so the runtime forwards it to the container exec TTY.
                                let cols = value
                                    .get("cols")
                                    .and_then(Value::as_u64)
                                    .unwrap_or(120)
                                    .clamp(1, 500) as u16;
                                let rows = value
                                    .get("rows")
                                    .and_then(Value::as_u64)
                                    .unwrap_or(40)
                                    .clamp(1, 250) as u16;
                                let mut guard = session.lock();
                                if first_resize {
                                    // A reconnect may replay a truncated ring; force a fresh TUI redraw even at the same grid size.
                                    let _ = guard.resize(if cols == 500 { 499 } else { cols + 1 }, rows);
                                    first_resize = false;
                                }
                                let _ = guard.resize(cols, rows);
                            }
                            Some("close") => break,
                            _ => {}
                        }
                    }
                    Some(Ok(_)) => {}
                    Some(Err(_)) | None => break,
                }
            }
            changed = updates.changed() => {
                if changed.is_err() { break; }
            }
        }
    }
    // Detaching drops only this subscriber; the single PTY reader continues draining output.
}
