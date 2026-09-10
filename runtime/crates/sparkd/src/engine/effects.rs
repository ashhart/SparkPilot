use super::*;

pub(super) struct Effects<'a> {
    pub(super) db: &'a Mutex<rusqlite::Connection>,
    pub(super) events: &'a EventBus,
    pub(super) node_id: &'a str,
    pub(super) guard: &'a Mutex<Option<Arc<crate::guard::MemoryGuardService>>>,
}

impl Effects<'_> {
    /// Track the exact loaded profile so the guard can mark it unsafe after a pressure failure.
    pub(super) fn guard_set_active(&self, active: Option<crate::guard::ActiveProfile>) {
        if let Some(guard) = self.guard.lock().as_ref() {
            guard.set_active_profile(active);
        }
    }

    pub(super) fn emit_event(
        &self,
        operation_id: Option<Uuid>,
        event_type: &str,
        severity: &str,
        payload: Value,
    ) {
        let conn = self.db.lock();
        self.events.emit(
            Some(&conn),
            self.node_id,
            operation_id,
            event_type,
            severity,
            payload,
        );
    }

    pub(super) fn persist_instance_state(
        &self,
        instance: &EngineInstance,
        state: &str,
        failure_code: Option<&str>,
    ) -> Result<(), String> {
        let mut conn = self.db.lock();
        let tx = conn.transaction().map_err(|error| error.to_string())?;
        tx.execute(
            r#"
                INSERT INTO inference_instances (
                    id, model_id, profile_id, node_id, state, container_id,
                    internal_port, started_at, failure_code, metadata_json
                ) VALUES (
                    ?1, ?2, ?3, ?4, ?5, ?6, ?7,
                    strftime('%Y-%m-%dT%H:%M:%fZ','now'), ?8, ?9
                )
                ON CONFLICT(id) DO UPDATE SET
                    state = excluded.state,
                    internal_port = excluded.internal_port,
                    failure_code = excluded.failure_code,
                    ready_at = CASE WHEN excluded.state = 'ready'
                        THEN strftime('%Y-%m-%dT%H:%M:%fZ','now')
                        ELSE inference_instances.ready_at END,
                    stopped_at = CASE WHEN excluded.state = 'stopped'
                        THEN strftime('%Y-%m-%dT%H:%M:%fZ','now')
                        ELSE inference_instances.stopped_at END
                "#,
            rusqlite::params![
                instance.instance_id.to_string(),
                instance.model_id,
                instance.profile_id,
                self.node_id,
                state,
                instance
                    .external_workload_id
                    .clone()
                    .unwrap_or_else(|| format!("spark-model-{}", instance.instance_id)),
                i64::from(instance.internal_port),
                failure_code,
                if instance.external_workload_id.is_some() {
                    r#"{"ownership_origin":"external_adoption"}"#
                } else {
                    "{}"
                },
            ],
        )
        .map_err(|error| format!("persist inference instance: {error}"))?;
        if state == "stopped" && instance.external_workload_id.is_none() {
            crate::pool::release_stopped_instance(&tx, instance.instance_id)
                .map_err(|e| e.to_string())?;
        }
        tx.commit().map_err(|error| error.to_string())
    }
}
