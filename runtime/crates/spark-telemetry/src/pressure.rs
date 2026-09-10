//! Use caller-supplied monotonic time, dwell and hysteresis; emergency recovery requires a verified stopped engine.

use std::time::Duration;

use crate::classify::{MemoryAction, classify_with_velocity};
use crate::signals::{MemoryPolicy, MemorySignals};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PressureState {
    Normal,
    Warning,
    Draining,
    Critical,
    Emergency,
    Recovering,
}

impl PressureState {
    /// Stable event/API name (internal ladder names, §33.3).
    pub fn as_str(self) -> &'static str {
        match self {
            PressureState::Normal => "normal",
            PressureState::Warning => "warning",
            PressureState::Draining => "draining",
            PressureState::Critical => "critical",
            PressureState::Emergency => "emergency",
            PressureState::Recovering => "recovering",
        }
    }

    /// Map internal Draining and Recovering to API critical until memory and services are verified.
    pub fn api_name(self) -> &'static str {
        match self {
            PressureState::Normal => "normal",
            PressureState::Warning => "warning",
            PressureState::Draining | PressureState::Critical | PressureState::Recovering => {
                "critical"
            }
            PressureState::Emergency => "emergency",
        }
    }

    fn rank(self) -> u32 {
        match self {
            PressureState::Normal => 0,
            PressureState::Warning => 1,
            PressureState::Draining => 2,
            PressureState::Critical => 3,
            PressureState::Emergency => 4,
            // Rank Recovering below Emergency so renewed engine danger can escalate again.
            PressureState::Recovering => 2,
        }
    }

    fn action(self) -> MemoryAction {
        match self {
            PressureState::Normal => MemoryAction::Continue,
            PressureState::Warning => MemoryAction::Warn,
            PressureState::Draining => MemoryAction::StopAdmissions,
            PressureState::Critical => MemoryAction::GracefulUnload,
            PressureState::Emergency => MemoryAction::EmergencyStop,
            PressureState::Recovering => MemoryAction::Continue,
        }
    }

    /// Clear only above the state's entry threshold plus recovery hysteresis.
    fn entry_threshold(self, policy: &MemoryPolicy) -> u64 {
        match self {
            PressureState::Normal | PressureState::Recovering => policy.critical_available_bytes,
            PressureState::Warning => policy.warning_available_bytes,
            PressureState::Draining => policy.draining_available_bytes(),
            PressureState::Critical => policy.critical_available_bytes,
            PressureState::Emergency => policy.emergency_available_bytes,
        }
    }
}

/// Why the machine moved (carried into events for diagnostics).
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum PressureReason {
    /// The classifier demanded a worse state for the minimum duration.
    Escalated(MemoryAction),
    /// Immediate entry requires kernel OOM, emergency floor or a qualified projected cliff.
    ImmediateEmergency,
    /// Sustained clearing above the entry threshold plus hysteresis.
    Recovered,
    /// The engine stopped after an emergency; verification begins.
    EngineStoppedVerifying,
    /// Signals worsened again while recovering.
    ReEscalated(MemoryAction),
}

impl PressureReason {
    pub fn as_str(self) -> &'static str {
        match self {
            PressureReason::Escalated(_) => "escalated",
            PressureReason::ImmediateEmergency => "immediate_emergency",
            PressureReason::Recovered => "recovered",
            PressureReason::EngineStoppedVerifying => "engine_stopped_verifying",
            PressureReason::ReEscalated(_) => "re_escalated",
        }
    }
}

/// A completed state change plus the action the entrant state demands.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct PressureTransition {
    pub from: PressureState,
    pub to: PressureState,
    pub action: MemoryAction,
    pub reason: PressureReason,
    pub available_bytes: u64,
}

/// Observation inputs beyond the memory sample itself.
#[derive(Debug, Clone, Copy, Default)]
pub struct ObservationContext {
    /// Whether an inference engine is running right now.
    pub engine_active: bool,
    /// Loading consumes memory toward an admitted reservation, so velocity alone is not danger.
    pub engine_loading: bool,
}

#[derive(Debug)]
pub struct PressureStateMachine {
    policy: MemoryPolicy,
    state: PressureState,
    /// (action, first_seen) of a persistently worse classification.
    escalation_candidate: Option<(MemoryAction, Duration)>,
    /// When headroom first cleared the de-escalation threshold.
    clearing_since: Option<Duration>,
    /// When the engine was first observed stopped in Emergency.
    engine_stopped_since: Option<Duration>,
}

impl PressureStateMachine {
    pub fn new(policy: MemoryPolicy) -> Self {
        Self {
            policy,
            state: PressureState::Normal,
            escalation_candidate: None,
            clearing_since: None,
            engine_stopped_since: None,
        }
    }

    pub fn state(&self) -> PressureState {
        self.state
    }

    pub fn policy(&self) -> &MemoryPolicy {
        &self.policy
    }

    /// Do not repeat EmergencyStop in Recovering while the engine is already stopped; resume escalation if it restarts.
    fn emergency_would_change_anything(&self, context: ObservationContext) -> bool {
        self.state != PressureState::Recovering || context.engine_active
    }

    /// Feed one observation. Returns a transition when the state changed.
    pub fn observe(
        &mut self,
        signals: &MemorySignals,
        context: ObservationContext,
        now: Duration,
    ) -> Option<PressureTransition> {
        // Missing procfs totals reset dwell timers; an unreadable interval cannot prove continuous pressure or recovery.
        if signals.total_bytes == 0 && !signals.kernel_oom_event {
            self.escalation_candidate = None;
            self.clearing_since = None;
            self.engine_stopped_since = None;
            return None;
        }
        let action = classify_with_velocity(signals, &self.policy, !context.engine_loading);

        // Kernel OOM, the emergency floor and a qualified cliff bypass escalation dwell.
        if action == MemoryAction::EmergencyStop
            && self.state != PressureState::Emergency
            && self.emergency_would_change_anything(context)
        {
            return self.enter(
                PressureState::Emergency,
                PressureReason::ImmediateEmergency,
                signals.available_bytes,
            );
        }

        // Require worse signals to persist for the minimum escalation duration.
        if action.rank() > self.state.rank() && self.emergency_would_change_anything(context) {
            let since = match &self.escalation_candidate {
                // Accumulate dwell across changing worse actions; clear candidacy only when pressure is no longer above the current state.
                Some((_, first)) => *first,
                None => now,
            };
            self.escalation_candidate = Some((action, since));
            self.clearing_since = None;
            let held = now.saturating_sub(since);
            if held >= Duration::from_secs(self.policy.escalation_minimum_seconds) {
                let reason = if self.state == PressureState::Recovering {
                    PressureReason::ReEscalated(action)
                } else {
                    PressureReason::Escalated(action)
                };
                return self.enter(action_state(action), reason, signals.available_bytes);
            }
            return None;
        }

        self.escalation_candidate = None;

        // Leave Emergency through Recovering only after the engine is verified stopped (ADR-008).
        if self.state == PressureState::Emergency {
            if !context.engine_active {
                let since = *self.engine_stopped_since.get_or_insert(now);
                if now.saturating_sub(since) >= Duration::from_secs(1) {
                    return self.enter(
                        PressureState::Recovering,
                        PressureReason::EngineStoppedVerifying,
                        signals.available_bytes,
                    );
                }
            } else {
                self.engine_stopped_since = None;
            }
            return None;
        }

        if self.state == PressureState::Normal {
            return None;
        }

        // De-escalate one step after sustained headroom above the entry threshold plus hysteresis.
        let clearing_threshold =
            self.state.entry_threshold(&self.policy) + self.policy.recovery_hysteresis_bytes;
        if signals.available_bytes > clearing_threshold && !signals.kernel_oom_event {
            let since = *self.clearing_since.get_or_insert(now);
            if now.saturating_sub(since)
                >= Duration::from_secs(self.policy.recovery_hysteresis_seconds)
            {
                return self.enter(
                    milder(self.state),
                    PressureReason::Recovered,
                    signals.available_bytes,
                );
            }
        } else {
            self.clearing_since = None;
        }

        None
    }

    fn enter(
        &mut self,
        to: PressureState,
        reason: PressureReason,
        available_bytes: u64,
    ) -> Option<PressureTransition> {
        let from = self.state;
        if from == to {
            return None;
        }
        self.state = to;
        self.escalation_candidate = None;
        self.clearing_since = None;
        self.engine_stopped_since = None;
        Some(PressureTransition {
            action: to.action(),
            from,
            to,
            reason,
            available_bytes,
        })
    }
}

fn action_state(action: MemoryAction) -> PressureState {
    match action {
        MemoryAction::Continue => PressureState::Normal,
        MemoryAction::Warn => PressureState::Warning,
        MemoryAction::StopAdmissions => PressureState::Draining,
        MemoryAction::GracefulUnload => PressureState::Critical,
        MemoryAction::EmergencyStop => PressureState::Emergency,
    }
}

fn milder(state: PressureState) -> PressureState {
    match state {
        PressureState::Recovering => PressureState::Normal,
        PressureState::Emergency => PressureState::Recovering,
        PressureState::Critical => PressureState::Draining,
        PressureState::Draining => PressureState::Warning,
        PressureState::Warning | PressureState::Normal => PressureState::Normal,
    }
}

#[cfg(test)]
#[path = "pressure/tests.rs"]
mod tests;
