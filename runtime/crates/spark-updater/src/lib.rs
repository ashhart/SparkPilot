//! Commit staged updates only after identity, database, helper, discovery and inventory checks pass; reuse installer verification.

pub mod apply;
pub mod health;
pub mod os_update;

pub const HEALTH_CHECK_DEFAULT_SECONDS: u64 = 60;

pub use health::{HealthCheck, HealthReport, HealthStatus, run_health_gate};
