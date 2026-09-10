//! Guest shared access: the per-guest policy, its schedule arithmetic and the records that enforce it.

mod routes;
pub use routes::{GUEST_ROUTES, guest_may_reach, restrict_guest_routes};

pub(crate) mod budget;
mod gate;
pub use gate::{
    GUEST_FORBIDDEN_PARAMETERS, GuestAdmission, admit, allowed_models, refuse_guest,
    reject_forbidden_parameters,
};

mod concurrency;
pub use concurrency::{GuestConcurrency, GuestSlot};

mod records;
pub use records::{
    GuestGrant, UsageTotals, bind_grant_to_device, daily_usage, effective_role,
    grant_by_invitation, grant_for_device, insert_grant, list_grants, record_refusal,
    record_request, refusals_by_reason, set_grant_state, tokens_used_on, update_policy, usage_over,
};

mod policy;
pub use policy::{
    DaySchedule, GrantState, GuestAttempt, GuestPolicy, GuestRefusal, HourWindow,
    MAX_ALLOWED_MODELS, MAX_CONCURRENT_REQUESTS, MAX_DAILY_TOKEN_BUDGET, MAX_WINDOWS_PER_DAY,
    MINUTES_PER_DAY, PolicyProblem, WeeklySchedule, evaluate,
};

mod timezone;
pub use timezone::{LocalTime, TimeZone, TimeZoneError};
