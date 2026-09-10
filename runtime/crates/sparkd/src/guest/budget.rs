//! Precharge bounded generation before dispatch; uncertain completion keeps its charge across restarts.
use super::{
    GuestAdmission,
    policy::{GuestAttempt, evaluate},
    records,
    timezone::TimeZone,
};
use crate::state::AppState;
use parking_lot::Mutex;
use serde_json::Value;
use std::sync::Arc;

#[derive(Debug)]
pub(crate) struct Reservation {
    database: Arc<Mutex<rusqlite::Connection>>,
    device: uuid::Uuid,
    day: String,
    prompt: u64,
    completion: u64,
    settled: Mutex<bool>,
}

impl Reservation {
    /// Called only for a complete, internally consistent final usage record.
    pub(crate) fn settle(&self, prompt: u64, completion: u64) {
        let mut settled = self.settled.lock();
        if *settled {
            return;
        }
        let conn = self.database.lock();
        let result = conn.execute(
            "UPDATE guest_usage SET prompt_tokens=MAX(0,prompt_tokens-?3)+?5,
             completion_tokens=MAX(0,completion_tokens-?4)+?6 WHERE device_id=?1 AND local_day=?2",
            rusqlite::params![
                self.device.to_string(),
                self.day,
                self.prompt,
                self.completion,
                prompt,
                completion
            ],
        );
        match result {
            Ok(1) => *settled = true,
            _ => tracing::error!(
                "guest reservation could not be reconciled; retaining reserved budget"
            ),
        }
    }
}

/// The SQLite connection lock covers both the remaining-budget check and the durable charge.
pub(crate) fn reserve(
    state: &AppState,
    admission: &GuestAdmission,
    model: &str,
    prompt: u64,
    requested_completion: u64,
) -> Result<(Arc<Reservation>, u64), &'static str> {
    let database = state.database.as_ref().ok_or("GUEST_BUDGET_UNAVAILABLE")?;
    let conn = database.lock();
    let grant = records::grant_for_device(&conn, &admission.device_id)
        .map_err(|_| "GUEST_BUDGET_UNAVAILABLE")?
        .ok_or("GUEST_ACCESS_REVOKED")?;
    let zone = TimeZone::load(&grant.policy.time_zone).map_err(|_| "GUEST_SCHEDULE_UNAVAILABLE")?;
    let used = records::tokens_used_on(&conn, &admission.device_id, &admission.local_day)
        .map_err(|_| "GUEST_BUDGET_UNAVAILABLE")?;
    evaluate(
        &grant.policy,
        &zone,
        &GuestAttempt {
            model_id: model,
            now_unix: state.clock.now().unix_timestamp(),
            active_requests: 0,
            tokens_used_today: used,
        },
    )
    .map_err(|refusal| refusal.code())?;
    let available = grant
        .policy
        .daily_token_budget
        .saturating_sub(used)
        .saturating_sub(prompt);
    let completion = available.min(requested_completion);
    if completion == 0 || prompt >= grant.policy.daily_token_budget.saturating_sub(used) {
        return Err("GUEST_BUDGET_EXHAUSTED");
    }
    records::record_request(
        &conn,
        &admission.device_id,
        &admission.local_day,
        prompt,
        completion,
        &state.clock.now_rfc3339(),
    )
    .map_err(|_| "GUEST_BUDGET_UNAVAILABLE")?;
    Ok((
        Arc::new(Reservation {
            database: database.clone(),
            device: admission.device_id,
            day: admission.local_day.clone(),
            prompt,
            completion,
            settled: Mutex::new(false),
        }),
        completion,
    ))
}

/// Only text chat is tokenized here: media and Responses have different accounting semantics.
pub(crate) fn text_messages(body: &Value) -> Option<&Value> {
    let messages = body.get("messages")?;
    messages
        .as_array()?
        .iter()
        .all(|message| {
            message.get("content").is_some_and(|content| {
                content.is_string()
                    || content.as_array().is_some_and(|parts| {
                        parts.iter().all(|part| {
                            part.get("type").and_then(Value::as_str) == Some("text")
                                && part.get("text").is_some_and(Value::is_string)
                        })
                    })
            })
        })
        .then_some(messages)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{clock::ManualUtcClock, state::RuntimeConfig};
    use spark_core::identity::{FileIdentityStore, IdentityStore};

    fn fixture() -> (AppState, GuestAdmission, tempfile::TempDir) {
        let directory = tempfile::tempdir().unwrap();
        let identity = FileIdentityStore::new(directory.path().join("identity"))
            .load_or_create("budget-test")
            .unwrap();
        let mut conn = rusqlite::Connection::open_in_memory().unwrap();
        crate::migration::migrate(&mut conn).unwrap();
        let owner = uuid::Uuid::new_v4();
        let device = uuid::Uuid::new_v4();
        for (id, role) in [(owner, "owner"), (device, "observer")] {
            crate::store::insert_device(
                &conn,
                &id,
                "Test",
                "ios",
                id.as_bytes(),
                &id.to_string(),
                role,
            )
            .unwrap();
        }
        let invitation = uuid::Uuid::new_v4();
        conn.execute("INSERT INTO pairing_invitations (id,role,nonce_hash,issued_by_device_id,issued_at,expires_at,signed_payload_json)
            VALUES (?1,'guest',?2,?3,'2026-01-01T00:00:00Z','2026-01-08T00:00:00Z','{}')",
            rusqlite::params![invitation.to_string(), invitation.as_bytes().to_vec(), owner.to_string()]).unwrap();
        let policy = crate::guest::GuestPolicy {
            state: crate::guest::GrantState::Active,
            display_name: "Test".into(),
            allowed_models: vec!["model".into()],
            allowed_hours: crate::guest::WeeklySchedule::everyday(&[crate::guest::HourWindow {
                start_minute: 0,
                end_minute: 1440,
            }]),
            time_zone: "Europe/London".into(),
            max_concurrent_requests: 8,
            daily_token_budget: 100,
            expires_at: None,
        };
        records::insert_grant(&conn, &invitation, &owner, &policy, "2026-01-01T00:00:00Z").unwrap();
        records::bind_grant_to_device(&conn, &invitation, &device, "2026-01-01T00:00:00Z").unwrap();
        records::set_grant_state(
            &conn,
            &device,
            crate::guest::GrantState::Active,
            "2026-01-01T00:00:00Z",
        )
        .unwrap();
        let state = AppState::new_with_clock(
            RuntimeConfig {
                api_major: 1,
                runtime_version: "test".into(),
                listen: "127.0.0.1:0".parse().unwrap(),
                node_name: "budget-test".into(),
                data_dir: directory.path().to_owned(),
                advertise: false,
                tls: false,
            },
            identity,
            Arc::new(spark_telemetry::FakeSystemMonitor),
            None,
            Arc::new(ManualUtcClock::new(
                time::OffsetDateTime::from_unix_timestamp(1_782_928_800).unwrap(),
            )),
        )
        .with_database(Arc::new(Mutex::new(conn)));
        let admission = GuestAdmission {
            remaining_tokens: 100,
            device_id: device,
            local_day: "2026-07-01".into(),
            slot: state.guest_concurrency.acquire_below(&device, 8).unwrap(),
        };
        (state, admission, directory)
    }

    #[test]
    fn cancellation_and_missing_usage_keep_a_durable_charge_and_reconciliation_is_once() {
        let (state, guest, _dir) = fixture();
        let (first, cap) = reserve(&state, &guest, "model", 10, 60).unwrap();
        assert_eq!(cap, 60);
        let (second, cap) = reserve(&state, &guest, "model", 10, 60).unwrap();
        assert_eq!(cap, 20);
        assert_eq!(
            reserve(&state, &guest, "model", 1, 1).unwrap_err(),
            "GUEST_BUDGET_EXHAUSTED"
        );
        drop(second); // Missing usage or disconnect never refunds an uncertain generation.
        first.settle(10, 15);
        first.settle(10, 15);
        let database = state.database.as_ref().unwrap();
        let usage =
            records::daily_usage(&database.lock(), &guest.device_id, &guest.local_day).unwrap();
        assert_eq!(usage.total_tokens(), 55);
        assert_eq!(usage.requests, 2);
    }

    #[test]
    fn guest_budget_counts_the_whole_prompt_and_refuses_revoked_access() {
        let (state, guest, _dir) = fixture();
        assert_eq!(
            reserve(&state, &guest, "model", 100, 1).unwrap_err(),
            "GUEST_BUDGET_EXHAUSTED"
        );
        let db = state.database.as_ref().unwrap();
        records::set_grant_state(
            &db.lock(),
            &guest.device_id,
            crate::guest::GrantState::Revoked,
            "2026-07-01T18:00:00Z",
        )
        .unwrap();
        assert_eq!(
            reserve(&state, &guest, "model", 1, 10).unwrap_err(),
            "GUEST_ACCESS_REVOKED"
        );
    }
}
