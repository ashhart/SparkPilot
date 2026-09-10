//! The Spark-wide rolling hour, reserved before a request goes out and written down the moment it ends.

use std::sync::{Arc, LazyLock};

use parking_lot::Mutex;

use super::session::ToolCallRecord;

/// One rolling hour, in seconds.
pub const HOUR_SECONDS: i64 = 3_600;

/// Every outbound request takes a place in the hour first, and leaves a record behind afterwards.
pub trait CallLedger: Send + Sync {
    /// True when this request may be made; false when the Spark has already spent its hour.
    fn reserve(&self, ceiling: usize, now: i64) -> bool;
    /// Write down a call that has just finished, so a crash cannot lose what already went out.
    fn append(&self, record: &ToolCallRecord);
}

/// The fallback for a runtime with no database: one counter per process, shared by every run in it.
#[derive(Debug, Default)]
pub struct ProcessLedger;

/// When each of this process's outbound requests was made, pruned to the last hour on every reservation.
static SPENT: LazyLock<Mutex<Vec<i64>>> = LazyLock::new(|| Mutex::new(Vec::new()));

impl ProcessLedger {
    pub fn shared() -> Arc<dyn CallLedger> {
        Arc::new(Self)
    }
}

impl CallLedger for ProcessLedger {
    fn reserve(&self, ceiling: usize, now: i64) -> bool {
        let mut spent = SPENT.lock();
        spent.retain(|at| now.saturating_sub(*at) < HOUR_SECONDS);
        if spent.len() >= ceiling {
            return false;
        }
        spent.push(now);
        true
    }

    /// A process with no database has nowhere durable to write; the run's own records still carry it.
    fn append(&self, _record: &ToolCallRecord) {}
}
