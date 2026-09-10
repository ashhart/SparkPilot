//! The per-guest policy and the pure decision that admits or refuses one guest inference request.

use axum::http::StatusCode;

use serde::{Deserialize, Serialize};

use crate::guest::timezone::{TimeZone, TimeZoneError};

/// Cap the model list so one policy cannot become an unbounded allowlist.
pub const MAX_ALLOWED_MODELS: usize = 32;

/// Cap windows per day; a real schedule is one or two blocks.
pub const MAX_WINDOWS_PER_DAY: usize = 4;

/// Never admit more simultaneous guest requests than a household Spark can serve.
pub const MAX_CONCURRENT_REQUESTS: u32 = 8;

/// Cap the daily budget so a typo cannot mean "no limit at all".
pub const MAX_DAILY_TOKEN_BUDGET: u64 = 100_000_000;

/// Minutes in a day; a window end of 1440 means "until local midnight".
pub const MINUTES_PER_DAY: u16 = 1440;

/// Where a guest grant is in its lifecycle. Only Active can run inference.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum GrantState {
    /// The guest has paired but the owner has not yet confirmed with presence.
    Pending,
    Active,
    Paused,
    Revoked,
}

impl GrantState {
    pub fn parse(value: &str) -> GrantState {
        match value {
            "active" => GrantState::Active,
            "paused" => GrantState::Paused,
            "revoked" => GrantState::Revoked,
            _ => GrantState::Pending,
        }
    }

    pub fn name(self) -> &'static str {
        match self {
            GrantState::Pending => "pending",
            GrantState::Active => "active",
            GrantState::Paused => "paused",
            GrantState::Revoked => "revoked",
        }
    }
}

/// One block of allowed local time. `end_minute` is exclusive.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct HourWindow {
    pub start_minute: u16,
    pub end_minute: u16,
}

/// One weekday's allowed blocks. Monday is 0.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DaySchedule {
    pub weekday: u8,
    pub windows: Vec<HourWindow>,
}

/// The seven days of a guest's allowed hours, always in the owner's time zone.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct WeeklySchedule {
    pub days: Vec<DaySchedule>,
}

impl WeeklySchedule {
    pub fn everyday(windows: &[HourWindow]) -> WeeklySchedule {
        WeeklySchedule {
            days: (0..7)
                .map(|weekday| DaySchedule {
                    weekday,
                    windows: windows.to_vec(),
                })
                .collect(),
        }
    }

    pub fn weekdays(windows: &[HourWindow]) -> WeeklySchedule {
        WeeklySchedule {
            days: (0..7)
                .map(|weekday| DaySchedule {
                    weekday,
                    windows: if weekday < 5 {
                        windows.to_vec()
                    } else {
                        Vec::new()
                    },
                })
                .collect(),
        }
    }

    /// A schedule with no open minute at all, the safe default before the owner chooses.
    pub fn closed() -> WeeklySchedule {
        WeeklySchedule::everyday(&[])
    }

    /// Every hour of every day, for an owner who only wants to limit models and tokens.
    pub fn always() -> WeeklySchedule {
        WeeklySchedule::everyday(&[HourWindow {
            start_minute: 0,
            end_minute: MINUTES_PER_DAY,
        }])
    }

    fn is_open_at(&self, weekday: u8, minute_of_day: u16) -> bool {
        self.days.iter().any(|day| {
            day.weekday == weekday
                && day.windows.iter().any(|window| {
                    minute_of_day >= window.start_minute && minute_of_day < window.end_minute
                })
        })
    }
}

/// What the owner decided one guest may do.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GuestPolicy {
    pub state: GrantState,
    pub display_name: String,
    pub allowed_models: Vec<String>,
    pub allowed_hours: WeeklySchedule,
    pub time_zone: String,
    pub max_concurrent_requests: u32,
    pub daily_token_budget: u64,
    pub expires_at: Option<i64>,
}

/// Why a policy the owner submitted cannot be stored.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum PolicyProblem {
    #[error("a guest may be allowed at most {MAX_ALLOWED_MODELS} models")]
    TooManyModels,
    #[error("a model identifier must be 1 to 200 characters")]
    ModelIdentifier,
    #[error("the allowed hours must name each of the seven weekdays once")]
    Weekdays,
    #[error("each day may have at most {MAX_WINDOWS_PER_DAY} time windows")]
    TooManyWindows,
    #[error("a time window must start before it ends and finish by midnight")]
    Window,
    #[error("time windows on one day must not overlap")]
    OverlappingWindows,
    #[error("concurrent requests must be 1 to {MAX_CONCURRENT_REQUESTS}")]
    Concurrency,
    #[error("the daily token budget must be 1 to {MAX_DAILY_TOKEN_BUDGET}")]
    Budget,
    #[error("the guest name must be 1 to 60 characters")]
    DisplayName,
    #[error("{0}")]
    TimeZone(#[from] TimeZoneError),
}

impl GuestPolicy {
    /// Reject a policy the owner could not have meant before it reaches the database.
    pub fn validate(&self) -> Result<(), PolicyProblem> {
        if !(1..=60).contains(&self.display_name.chars().count()) {
            return Err(PolicyProblem::DisplayName);
        }
        if self.allowed_models.len() > MAX_ALLOWED_MODELS {
            return Err(PolicyProblem::TooManyModels);
        }
        if self
            .allowed_models
            .iter()
            .any(|model| !(1..=200).contains(&model.chars().count()))
        {
            return Err(PolicyProblem::ModelIdentifier);
        }
        self.validate_schedule()?;
        if !(1..=MAX_CONCURRENT_REQUESTS).contains(&self.max_concurrent_requests) {
            return Err(PolicyProblem::Concurrency);
        }
        if !(1..=MAX_DAILY_TOKEN_BUDGET).contains(&self.daily_token_budget) {
            return Err(PolicyProblem::Budget);
        }
        TimeZone::load(&self.time_zone)?;
        Ok(())
    }

    fn validate_schedule(&self) -> Result<(), PolicyProblem> {
        if self.allowed_hours.days.len() != 7 {
            return Err(PolicyProblem::Weekdays);
        }
        let mut seen = [false; 7];
        for day in &self.allowed_hours.days {
            let index = usize::from(day.weekday);
            if index >= 7 || seen[index] {
                return Err(PolicyProblem::Weekdays);
            }
            seen[index] = true;
            if day.windows.len() > MAX_WINDOWS_PER_DAY {
                return Err(PolicyProblem::TooManyWindows);
            }
            for window in &day.windows {
                if window.start_minute >= window.end_minute || window.end_minute > MINUTES_PER_DAY {
                    return Err(PolicyProblem::Window);
                }
            }
            for (position, window) in day.windows.iter().enumerate() {
                if day.windows[position + 1..].iter().any(|other| {
                    window.start_minute < other.end_minute && other.start_minute < window.end_minute
                }) {
                    return Err(PolicyProblem::OverlappingWindows);
                }
            }
        }
        Ok(())
    }
}

/// One guest inference attempt, with the counters the gate compares against the policy.
#[derive(Debug, Clone, Copy)]
pub struct GuestAttempt<'a> {
    pub model_id: &'a str,
    pub now_unix: i64,
    pub active_requests: u32,
    pub tokens_used_today: u64,
}

/// Why one guest request was refused. Every variant has a documented error code.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GuestRefusal {
    AwaitingOwner,
    Paused,
    Revoked,
    Expired,
    ModelNotAllowed,
    OutsideHours,
    BudgetExhausted,
    ConcurrencyLimit,
    ScheduleUnavailable,
}

impl GuestRefusal {
    pub fn code(self) -> &'static str {
        match self {
            GuestRefusal::AwaitingOwner => "GUEST_AWAITING_OWNER",
            GuestRefusal::Paused => "GUEST_ACCESS_PAUSED",
            GuestRefusal::Revoked => "GUEST_ACCESS_REVOKED",
            GuestRefusal::Expired => "GUEST_ACCESS_EXPIRED",
            GuestRefusal::ModelNotAllowed => "GUEST_MODEL_NOT_ALLOWED",
            GuestRefusal::OutsideHours => "GUEST_OUTSIDE_HOURS",
            GuestRefusal::BudgetExhausted => "GUEST_BUDGET_EXHAUSTED",
            GuestRefusal::ConcurrencyLimit => "GUEST_CONCURRENCY_LIMIT",
            GuestRefusal::ScheduleUnavailable => "GUEST_SCHEDULE_UNAVAILABLE",
        }
    }

    pub fn message(self) -> &'static str {
        match self {
            GuestRefusal::AwaitingOwner => {
                "the owner of this Spark has not confirmed your access yet"
            }
            GuestRefusal::Paused => "the owner has paused your access to this Spark",
            GuestRefusal::Revoked => "your access to this Spark has been withdrawn",
            GuestRefusal::Expired => "your access to this Spark has run out",
            GuestRefusal::ModelNotAllowed => "the owner has not shared this model with you",
            GuestRefusal::OutsideHours => {
                "you can use this Spark only during the hours the owner set"
            }
            GuestRefusal::BudgetExhausted => "you have used today's share of this Spark",
            GuestRefusal::ConcurrencyLimit => "wait for your other request to finish",
            GuestRefusal::ScheduleUnavailable => {
                "this Spark cannot read the time zone your hours are set in"
            }
        }
    }

    pub fn status(self) -> StatusCode {
        match self {
            GuestRefusal::BudgetExhausted | GuestRefusal::ConcurrencyLimit => {
                StatusCode::TOO_MANY_REQUESTS
            }
            GuestRefusal::ScheduleUnavailable => StatusCode::CONFLICT,
            _ => StatusCode::FORBIDDEN,
        }
    }
}

/// Decide one guest request. Pure: no clock, no database, no network.
pub fn evaluate(
    policy: &GuestPolicy,
    zone: &TimeZone,
    attempt: &GuestAttempt<'_>,
) -> Result<(), GuestRefusal> {
    match policy.state {
        GrantState::Revoked => return Err(GuestRefusal::Revoked),
        GrantState::Pending => return Err(GuestRefusal::AwaitingOwner),
        GrantState::Paused => return Err(GuestRefusal::Paused),
        GrantState::Active => {}
    }
    if policy.expires_at.is_some_and(|at| attempt.now_unix >= at) {
        return Err(GuestRefusal::Expired);
    }
    if !policy
        .allowed_models
        .iter()
        .any(|allowed| allowed == attempt.model_id)
    {
        return Err(GuestRefusal::ModelNotAllowed);
    }
    let local = zone
        .local_at(attempt.now_unix)
        .map_err(|_| GuestRefusal::ScheduleUnavailable)?;
    if !policy
        .allowed_hours
        .is_open_at(local.weekday, local.minute_of_day)
    {
        return Err(GuestRefusal::OutsideHours);
    }
    if attempt.tokens_used_today >= policy.daily_token_budget {
        return Err(GuestRefusal::BudgetExhausted);
    }
    if attempt.active_requests >= policy.max_concurrent_requests {
        return Err(GuestRefusal::ConcurrencyLimit);
    }
    Ok(())
}

#[cfg(test)]
#[path = "policy_tests.rs"]
mod tests;
