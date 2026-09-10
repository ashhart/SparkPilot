use super::*;

pub(super) struct CoordinationEvents<'a> {
    pub(super) database: &'a Mutex<Connection>,
    pub(super) identity: &'a NodeIdentity,
    pub(super) events: &'a Option<EventBus>,
}

impl CoordinationEvents<'_> {
    pub(super) fn emit_cluster_event(
        &self,
        cluster_id: Uuid,
        event_type: &str,
        severity: &str,
        mut payload: Value,
    ) {
        let Some(events) = &self.events else {
            return;
        };
        if let Some(object) = payload.as_object_mut() {
            object.insert(
                "cluster_id".to_owned(),
                Value::String(cluster_id.to_string()),
            );
        }
        let connection = self.database.lock();
        events.emit(
            Some(&connection),
            &self.identity.node_id().to_string(),
            None,
            event_type,
            severity,
            payload,
        );
    }
}
