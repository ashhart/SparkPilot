//! Apply thermal dwell and hysteresis; missing readings never prove safety, and unqualified thermal thresholds permit at most graceful unload.

use std::time::Duration;

use serde::Deserialize;

use crate::classify::MemoryAction;

/// Allow either accelerator or sysfs temperature to be unavailable independently.
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct ThermalSignals {
    /// Accelerator temperature, if the accelerator probe reported one.
    pub gpu_celsius: Option<f64>,
    /// Host/package temperature, if a thermal zone was readable.
    pub cpu_celsius: Option<f64>,
}

impl ThermalSignals {
    /// Return the hotter reported temperature, or None if neither sensor responded.
    pub fn hottest_celsius(&self) -> Option<f64> {
        match (self.gpu_celsius, self.cpu_celsius) {
            (Some(gpu), Some(cpu)) => Some(gpu.max(cpu)),
            (Some(value), None) | (None, Some(value)) => Some(value),
            (None, None) => None,
        }
    }
}

/// Serialize thermal thresholds and timings under thermal_guard configuration keys.
#[derive(Debug, Clone, Copy, PartialEq, Deserialize)]
#[serde(deny_unknown_fields, default)]
pub struct ThermalPolicy {
    /// First rung: report, change nothing.
    pub warning_celsius: f64,
    /// Stop admitting new load work while this persists.
    pub hot_celsius: f64,
    /// Ask the active engine to unload gracefully.
    pub critical_celsius: f64,
    /// Require sustained heat longer than memory-pressure dwell; one temperature sample must never trigger escalation.
    pub escalation_minimum_seconds: u64,
    /// Degrees below a state's entry threshold before it may clear.
    pub recovery_hysteresis_celsius: f64,
    /// How long the cooler reading must hold before de-escalating.
    pub recovery_hysteresis_seconds: u64,
}

impl Default for ThermalPolicy {
    fn default() -> Self {
        Self {
            warning_celsius: 75.0,
            hot_celsius: 84.0,
            critical_celsius: 90.0,
            escalation_minimum_seconds: 15,
            recovery_hysteresis_celsius: 5.0,
            recovery_hysteresis_seconds: 60,
        }
    }
}

/// Unknown means temperature could not be measured and must not be reported as Nominal.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ThermalState {
    Unknown,
    Nominal,
    Warm,
    Hot,
    Critical,
}

impl ThermalState {
    /// Stable event/API name.
    pub fn as_str(self) -> &'static str {
        match self {
            ThermalState::Unknown => "unknown",
            ThermalState::Nominal => "nominal",
            ThermalState::Warm => "warm",
            ThermalState::Hot => "hot",
            ThermalState::Critical => "critical",
        }
    }

    /// The guard action this state demands.
    pub fn action(self) -> MemoryAction {
        match self {
            // Unknown readings cannot demand a thermal action.
            ThermalState::Unknown | ThermalState::Nominal => MemoryAction::Continue,
            ThermalState::Warm => MemoryAction::Warn,
            ThermalState::Hot => MemoryAction::StopAdmissions,
            ThermalState::Critical => MemoryAction::GracefulUnload,
        }
    }

    fn rank(self) -> u32 {
        match self {
            ThermalState::Unknown => 0,
            ThermalState::Nominal => 0,
            ThermalState::Warm => 1,
            ThermalState::Hot => 2,
            ThermalState::Critical => 3,
        }
    }

    /// Clear only below the state's entry temperature minus the hysteresis margin.
    fn entry_threshold(self, policy: &ThermalPolicy) -> Option<f64> {
        match self {
            ThermalState::Unknown | ThermalState::Nominal => None,
            ThermalState::Warm => Some(policy.warning_celsius),
            ThermalState::Hot => Some(policy.hot_celsius),
            ThermalState::Critical => Some(policy.critical_celsius),
        }
    }
}

/// Pure threshold classification of a single sample.
pub fn classify_thermal(signals: &ThermalSignals, policy: &ThermalPolicy) -> ThermalState {
    let Some(celsius) = signals.hottest_celsius() else {
        return ThermalState::Unknown;
    };
    if celsius >= policy.critical_celsius {
        ThermalState::Critical
    } else if celsius >= policy.hot_celsius {
        ThermalState::Hot
    } else if celsius >= policy.warning_celsius {
        ThermalState::Warm
    } else {
        ThermalState::Nominal
    }
}

/// Why the machine moved.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum ThermalReason {
    /// A hotter classification persisted for the minimum duration.
    Escalated,
    /// A cooler reading held below the entry threshold minus hysteresis.
    Cooled,
    /// Sensors stopped reporting.
    EvidenceLost,
    /// Sensors started reporting again.
    EvidenceReturned,
}

impl ThermalReason {
    pub fn as_str(self) -> &'static str {
        match self {
            ThermalReason::Escalated => "escalated",
            ThermalReason::Cooled => "cooled",
            ThermalReason::EvidenceLost => "evidence_lost",
            ThermalReason::EvidenceReturned => "evidence_returned",
        }
    }
}

/// A completed thermal state change plus the action the new state demands.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct ThermalTransition {
    pub from: ThermalState,
    pub to: ThermalState,
    pub action: MemoryAction,
    pub reason: ThermalReason,
    pub celsius: Option<f64>,
}

/// Use caller-supplied monotonic time for escalation dwell, temperature/time hysteresis and one-step recovery.
#[derive(Debug)]
pub struct ThermalStateMachine {
    policy: ThermalPolicy,
    state: ThermalState,
    /// (state, first_seen) of a persistently hotter classification.
    escalation_candidate: Option<(ThermalState, Duration)>,
    /// When the reading first fell below the clearing threshold.
    cooling_since: Option<Duration>,
}

impl ThermalStateMachine {
    pub fn new(policy: ThermalPolicy) -> Self {
        Self {
            policy,
            state: ThermalState::Unknown,
            escalation_candidate: None,
            cooling_since: None,
        }
    }

    pub fn state(&self) -> ThermalState {
        self.state
    }

    pub fn policy(&self) -> &ThermalPolicy {
        &self.policy
    }

    /// Feed one observation. Returns a transition when the state changed.
    pub fn observe(
        &mut self,
        signals: &ThermalSignals,
        now: Duration,
    ) -> Option<ThermalTransition> {
        let observed = classify_thermal(signals, &self.policy);
        let celsius = signals.hottest_celsius();

        // Retain elevated posture during sensor loss; only a non-acting state may return to Unknown.
        if observed == ThermalState::Unknown {
            self.escalation_candidate = None;
            self.cooling_since = None;
            if self.state.rank() > ThermalState::Nominal.rank() {
                return None;
            }
            return self.move_to(ThermalState::Unknown, ThermalReason::EvidenceLost, celsius);
        }
        // Resume at the calm rung after sensor recovery and apply normal escalation dwell.
        if self.state == ThermalState::Unknown {
            self.escalation_candidate = None;
            self.cooling_since = None;
            if let Some(transition) = self.move_to(
                ThermalState::Nominal,
                ThermalReason::EvidenceReturned,
                celsius,
            ) {
                if observed.rank() > ThermalState::Nominal.rank() {
                    self.escalation_candidate = Some((observed, now));
                }
                return Some(transition);
            }
        }

        if observed.rank() > self.state.rank() {
            self.cooling_since = None;
            let minimum = Duration::from_secs(self.policy.escalation_minimum_seconds);
            // Preserve escalation dwell across hotter rung changes; readings back at the current rung are handled below.
            let since = match self.escalation_candidate {
                Some((_, first)) => first,
                None => now,
            };
            self.escalation_candidate = Some((observed, since));
            if now.saturating_sub(since) >= minimum {
                self.escalation_candidate = None;
                return self.move_to(observed, ThermalReason::Escalated, celsius);
            }
            return None;
        }

        // Keep candidacy at the current rung; only a cooler rung resets dwell, allowing sustained boundary oscillation to escalate.
        if observed.rank() < self.state.rank() {
            self.escalation_candidate = None;
            // Clear after temperature stays below the entry threshold minus margin for the hysteresis duration.
            let clear_below = self
                .state
                .entry_threshold(&self.policy)
                .map(|threshold| threshold - self.policy.recovery_hysteresis_celsius);
            let cleared = match (celsius, clear_below) {
                (Some(reading), Some(limit)) => reading < limit,
                _ => true,
            };
            if !cleared {
                self.cooling_since = None;
                return None;
            }
            let hold = Duration::from_secs(self.policy.recovery_hysteresis_seconds);
            match self.cooling_since {
                Some(since) if now.saturating_sub(since) >= hold => {
                    self.cooling_since = None;
                    // One step at a time, as the memory ladder does.
                    let next = self.one_step_down();
                    return self.move_to(next, ThermalReason::Cooled, celsius);
                }
                Some(_) => {}
                None => self.cooling_since = Some(now),
            }
        } else {
            self.cooling_since = None;
        }
        None
    }

    fn one_step_down(&self) -> ThermalState {
        match self.state {
            ThermalState::Critical => ThermalState::Hot,
            ThermalState::Hot => ThermalState::Warm,
            ThermalState::Warm => ThermalState::Nominal,
            other => other,
        }
    }

    fn move_to(
        &mut self,
        to: ThermalState,
        reason: ThermalReason,
        celsius: Option<f64>,
    ) -> Option<ThermalTransition> {
        if to == self.state {
            return None;
        }
        let from = self.state;
        self.state = to;
        Some(ThermalTransition {
            from,
            to,
            action: to.action(),
            reason,
            celsius,
        })
    }
}

#[cfg(test)]
#[path = "thermal/tests.rs"]
mod tests;
