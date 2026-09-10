//! UTC time source for persisted runtime records.

use std::sync::Arc;

use time::{OffsetDateTime, UtcOffset, format_description::well_known::Rfc3339};

/// Supplies UTC time to production services and deterministic tests.
pub trait UtcClock: Send + Sync + std::fmt::Debug {
    fn now(&self) -> OffsetDateTime;

    fn now_rfc3339(&self) -> String {
        self.now()
            .to_offset(UtcOffset::UTC)
            .format(&Rfc3339)
            .expect("UTC timestamps always format as RFC3339")
    }
}

/// Wall clock used by the running daemon.
#[derive(Debug, Clone, Copy, Default)]
pub struct SystemUtcClock;

impl UtcClock for SystemUtcClock {
    fn now(&self) -> OffsetDateTime {
        OffsetDateTime::now_utc()
    }
}

/// Format a UTC instant the way every persisted runtime record stores it.
pub fn format_utc(value: OffsetDateTime) -> String {
    value
        .to_offset(UtcOffset::UTC)
        .format(&Rfc3339)
        .expect("UTC timestamps always format as RFC3339")
}

pub fn system_clock() -> Arc<dyn UtcClock> {
    Arc::new(SystemUtcClock)
}

/// Inject deterministic time in tests; production uses SystemUtcClock.
#[derive(Debug)]
pub struct ManualUtcClock {
    now: parking_lot::Mutex<OffsetDateTime>,
}

impl ManualUtcClock {
    pub fn new(now: OffsetDateTime) -> Self {
        Self {
            now: parking_lot::Mutex::new(now),
        }
    }

    pub fn set(&self, now: OffsetDateTime) {
        *self.now.lock() = now;
    }

    pub fn advance(&self, duration: time::Duration) {
        *self.now.lock() += duration;
    }
}

impl UtcClock for ManualUtcClock {
    fn now(&self) -> OffsetDateTime {
        *self.now.lock()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_clock_advances_and_formats_in_utc() {
        let initial = OffsetDateTime::parse("2024-01-02T03:04:05Z", &Rfc3339).unwrap();
        let clock = ManualUtcClock::new(initial);

        assert_eq!(clock.now_rfc3339(), "2024-01-02T03:04:05Z");
        clock.advance(time::Duration::milliseconds(1250));
        assert_eq!(clock.now_rfc3339(), "2024-01-02T03:04:06.25Z");

        let offset = OffsetDateTime::parse("2024-01-02T04:04:05+01:00", &Rfc3339).unwrap();
        clock.set(offset);
        assert_eq!(clock.now_rfc3339(), "2024-01-02T03:04:05Z");
    }
}
