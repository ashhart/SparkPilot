//! Reserve the node's web allowance durably before every HTTP request, including robots and redirects.
use super::session::{MAX_CALLS_PER_HOUR, TransportRequest, TransportResponse, WebTransport};
use crate::{audit::AuditDraft, automations::runner::WebActor, clock::UtcClock};
use parking_lot::Mutex;
use rusqlite::Connection;
use serde_json::json;
use std::sync::Arc;

pub struct AuditedTransport {
    database: Arc<Mutex<Connection>>,
    clock: Arc<dyn UtcClock>,
    inner: Arc<dyn WebTransport>,
    actor: WebActor,
    limit: usize,
}

impl AuditedTransport {
    pub fn new(
        database: Arc<Mutex<Connection>>,
        clock: Arc<dyn UtcClock>,
        inner: Arc<dyn WebTransport>,
        actor: WebActor,
        limit: usize,
    ) -> Self {
        Self {
            database,
            clock,
            inner,
            actor,
            limit: limit.min(MAX_CALLS_PER_HOUR),
        }
    }

    fn reserve(&self, request: &TransportRequest) -> Result<i64, String> {
        let since = crate::clock::format_utc(self.clock.now() - time::Duration::hours(1));
        let mut conn = self.database.lock();
        let transaction = conn
            .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
            .map_err(|_| "AUDIT_UNAVAILABLE")?;
        let made: usize = transaction.query_row(
            "SELECT COUNT(*) FROM audit_records WHERE action='web.request.started' AND occurred_at >= ?1",[since],|r|r.get(0))
            .map_err(|_| "AUDIT_UNAVAILABLE")?;
        if made >= self.limit {
            return Err("WEB_HOURLY_LIMIT".into());
        }
        let host = reqwest::Url::parse(&request.url)
            .ok()
            .and_then(|u| u.host_str().map(str::to_owned));
        let record = crate::audit::append(
            &transaction,
            self.clock.as_ref(),
            &AuditDraft {
                actor_device_id: self.actor.device_id,
                actor_role: Some(&self.actor.role),
                source_route: "/web-tools",
                action: "web.request.started",
                resource: host.as_deref(),
                result: "accepted",
                operation_id: None,
                request_id: None,
                // The transport journal never retains query strings, page paths or credential headers.
                details: &json!({"method":"GET","host":host}),
            },
        )
        .map_err(|_| "AUDIT_UNAVAILABLE")?;
        transaction.commit().map_err(|_| "AUDIT_UNAVAILABLE")?;
        Ok(record.sequence)
    }
}

#[async_trait::async_trait]
impl WebTransport for AuditedTransport {
    async fn get(&self, request: &TransportRequest) -> Result<TransportResponse, String> {
        let reservation = self.reserve(request)?;
        let result = self.inner.get(request).await;
        let details = match &result {
            Ok(response) => {
                json!({"reservation":reservation,"status":response.status,"bytes":response.bytes})
            }
            Err(_) => json!({"reservation":reservation}),
        };
        crate::audit::append_committed(
            &self.database,
            self.clock.as_ref(),
            &AuditDraft {
                actor_device_id: self.actor.device_id,
                actor_role: Some(&self.actor.role),
                source_route: "/web-tools",
                action: "web.request.finished",
                resource: None,
                result: if result.is_ok() {
                    "succeeded"
                } else {
                    "failed"
                },
                operation_id: None,
                request_id: None,
                details: &details,
            },
        )
        .map_err(|_| "AUDIT_UNAVAILABLE")?;
        result
    }
}
