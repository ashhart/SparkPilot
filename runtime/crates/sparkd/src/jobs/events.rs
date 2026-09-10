//! What the operation family publishes and audits: one place that reads the persisted row back before it claims anything.

use super::*;

/// §60.2: publishing the operation family needs the bus and the node identity its envelope carries.
#[derive(Clone)]
pub(super) struct OperationEvents {
    pub(super) bus: crate::events::EventBus,
    pub(super) node_id: Arc<str>,
}

impl std::fmt::Debug for OperationEvents {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("OperationEvents")
            .field("node_id", &self.node_id)
            .finish()
    }
}

impl JobService {
    /// Read the persisted row back so an event never claims a transition the database did not take.
    pub(super) fn publish_operation(
        &self,
        conn: &Connection,
        id: Uuid,
        event_type: &str,
        severity: &str,
    ) {
        let Some(events) = self.events.as_ref() else {
            return;
        };
        let row = conn
            .query_row(
                "SELECT kind, state, stage, progress, error_code, resource_id
                   FROM operations WHERE id = ?1",
                [id.to_string()],
                |row| {
                    Ok(serde_json::json!({
                        "kind": row.get::<_, String>(0)?,
                        "state": row.get::<_, String>(1)?,
                        "stage": row.get::<_, Option<String>>(2)?,
                        "progress": row.get::<_, Option<f64>>(3)?,
                        "error_code": row.get::<_, Option<String>>(4)?,
                        "resource_id": row.get::<_, Option<String>>(5)?,
                    }))
                },
            )
            .optional();
        match row {
            Ok(Some(payload)) => events.bus.emit(
                Some(conn),
                &events.node_id,
                Some(id),
                event_type,
                severity,
                payload,
            ),
            Ok(None) => tracing::warn!(%id, event_type, "operation row vanished before its event"),
            Err(error) => {
                tracing::error!(%error, %id, event_type, "operation event payload unreadable")
            }
        }
    }

    /// §60.2 names one type per terminal state so a client can act without re-reading the row.
    pub(super) fn terminal_event(state: &str) -> (&'static str, &'static str) {
        match state {
            "succeeded" => ("operation.completed", "info"),
            "cancelled" => ("operation.cancelled", "notice"),
            _ => ("operation.failed", "warning"),
        }
    }

    /// A worker that finished after losing its lease is audited and published, never silently dropped.
    pub(super) fn record_lost_lease(
        &self,
        conn: &Connection,
        id: Uuid,
        fence: i64,
        requested_state: &str,
        error_code: Option<&str>,
    ) {
        tracing::warn!(
            %id,
            fence,
            requested_state,
            error_code,
            "a worker finished after its operation lease was taken from it; its result is discarded"
        );
        let details = serde_json::json!({
            "held_fence": fence,
            "requested_state": requested_state,
            "error_code": error_code,
        });
        let appended = crate::audit::append(
            conn,
            self.clock.as_ref(),
            &crate::audit::AuditDraft {
                actor_device_id: None,
                actor_role: None,
                source_route: "/jobs/lease",
                action: "operation.lease.lost",
                resource: None,
                result: "refused",
                operation_id: Some(id),
                request_id: None,
                details: &details,
            },
        );
        if let Err(error) = appended {
            tracing::error!(%error, %id, "a lost operation lease could not be audited");
        }
        if let Some(events) = self.events.as_ref() {
            events.bus.emit(
                Some(conn),
                &events.node_id,
                Some(id),
                "operation.lease.lost",
                "warning",
                details,
            );
        }
    }
}
