//! Derive a profile's launch reservation from recipe arithmetic instead of a fixed share of unified memory (ADR-043).

use crate::recipe::{ENGINE_MAX_SEQUENCES, Memory, ModelRecipe, Profile, RecipeError};

/// Projected contexts are reported in whole blocks so the figure is a usable engine setting, not a fraction.
pub const CONTEXT_STEP_TOKENS: u64 = 4096;

/// The helper accepts utilisation shares between 40% and 90%; a derived share is clamped into that policy.
pub const UTILISATION_FLOOR_MILLI: u16 = 400;
pub const UTILISATION_CEILING_MILLI: u16 = 900;

/// The four parts of one profile's reservation; the total is what admission and the container cap budget.
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize)]
pub struct MemoryReservation {
    pub weight_bytes: u64,
    pub kv_cache_bytes: u64,
    pub state_bytes: u64,
    pub engine_overhead_bytes: u64,
}

impl MemoryReservation {
    /// None when the recipe carries no per-token figures or when the arithmetic overflows.
    pub fn derive(memory: &Memory, profile: &Profile) -> Option<Self> {
        let kv_per_token = memory.kv_cache_bytes_per_token?;
        let state_per_sequence = memory.state_bytes_per_sequence?;
        let sequences = u64::from(profile.max_sequences);
        let kv_cache_bytes = kv_per_token
            .checked_mul(profile.max_model_length)?
            .checked_mul(sequences)?;
        let state_bytes = state_per_sequence.checked_mul(sequences)?;
        let reservation = Self {
            weight_bytes: memory.expected_weight_bytes,
            kv_cache_bytes,
            state_bytes,
            engine_overhead_bytes: memory.expected_engine_overhead_bytes,
        };
        reservation.checked_total().map(|_| reservation)
    }

    pub fn checked_total(&self) -> Option<u64> {
        self.weight_bytes
            .checked_add(self.kv_cache_bytes)?
            .checked_add(self.state_bytes)?
            .checked_add(self.engine_overhead_bytes)
    }

    /// Weights plus cache plus state plus overhead; `derive` already proved this cannot overflow.
    pub fn total_bytes(&self) -> u64 {
        self.checked_total().unwrap_or(u64::MAX)
    }

    /// vLLM allocates recurrent state from the same pool as the KV cache, so both go into its cache budget.
    pub fn engine_cache_bytes(&self) -> u64 {
        self.kv_cache_bytes.saturating_add(self.state_bytes)
    }
}

impl ModelRecipe {
    /// Refuse half-declared arithmetic, overflow, and a declared peak that disagrees with the recipe's own numbers.
    pub(crate) fn validate_memory_arithmetic(&self) -> Result<(), RecipeError> {
        let memory = &self.memory;
        match (
            memory.kv_cache_bytes_per_token,
            memory.state_bytes_per_sequence,
        ) {
            (None, None) => return Ok(()),
            (Some(kv), Some(state)) if kv > 0 && state > 0 => {}
            _ => {
                return Err(RecipeError::InvalidMemoryArithmetic(
                    "kvCacheBytesPerToken and stateBytesPerSequence must both be present and positive".into(),
                ));
            }
        }
        for profile in &self.profiles {
            let Some(derived) = MemoryReservation::derive(memory, profile) else {
                return Err(RecipeError::InvalidMemoryArithmetic(format!(
                    "{} reservation overflows",
                    profile.id
                )));
            };
            if profile.expected_peak_bytes != derived.total_bytes() {
                return Err(RecipeError::PeakDisagreesWithArithmetic {
                    profile: profile.id.clone(),
                    declared: profile.expected_peak_bytes,
                    derived: derived.total_bytes(),
                });
            }
        }
        Ok(())
    }

    /// The breakdown behind a profile's reservation, when the recipe declares its arithmetic.
    pub fn reservation(&self, profile: &Profile) -> Option<MemoryReservation> {
        MemoryReservation::derive(&self.memory, profile)
    }

    /// Bytes a launch of this profile must be able to take: derived when possible, else the declared peak.
    pub fn profile_reservation_bytes(&self, profile: &Profile) -> u64 {
        self.reservation(profile)
            .map(|reservation| reservation.total_bytes())
            .unwrap_or(profile.expected_peak_bytes)
    }

    /// The utilisation share vLLM must see free at start-up: the reservation's share of unified memory, within the helper's 40-90% policy.
    pub fn launch_utilisation_milli(&self, profile: &Profile, total_memory_bytes: u64) -> u16 {
        let declared = (profile.gpu_memory_utilisation * 1000.0).round() as u16;
        let Some(reservation) = self.reservation(profile) else {
            return declared;
        };
        if total_memory_bytes == 0 {
            return declared;
        }
        // vLLM refuses to start when free memory is below this share of the device, so it must not exceed what the launch needs.
        let share = u128::from(reservation.total_bytes()) * 1000;
        let milli = share.div_ceil(u128::from(total_memory_bytes));
        u16::try_from(milli.clamp(
            u128::from(UTILISATION_FLOOR_MILLI),
            u128::from(UTILISATION_CEILING_MILLI),
        ))
        .unwrap_or(UTILISATION_CEILING_MILLI)
    }

    /// Largest context, in whole 4096-token blocks, that `budget_bytes` admits at the profile's request count.
    pub fn max_context_that_fits(&self, profile: &Profile, budget_bytes: u64) -> Option<u64> {
        let kv_per_token = self.memory.kv_cache_bytes_per_token?;
        let state_per_sequence = self.memory.state_bytes_per_sequence?;
        let sequences = u64::from(profile.max_sequences);
        let per_token = kv_per_token.checked_mul(sequences)?;
        let remaining = budget_bytes
            .saturating_sub(self.memory.expected_weight_bytes)
            .saturating_sub(self.memory.expected_engine_overhead_bytes)
            .saturating_sub(state_per_sequence.saturating_mul(sequences));
        let tokens = remaining / per_token.max(1) / CONTEXT_STEP_TOKENS * CONTEXT_STEP_TOKENS;
        // A recipe's longest profile stands in for the model's position limit, which the recipe does not carry.
        let ceiling = self
            .profiles
            .iter()
            .map(|candidate| candidate.max_model_length)
            .max()
            .unwrap_or(profile.max_model_length);
        Some(tokens.min(ceiling))
    }

    /// Requests that `budget_bytes` admits at the profile's full context, bounded by the engine policy.
    pub fn max_sequences_that_fit(&self, profile: &Profile, budget_bytes: u64) -> Option<u32> {
        let kv_per_token = self.memory.kv_cache_bytes_per_token?;
        let state_per_sequence = self.memory.state_bytes_per_sequence?;
        let per_sequence = kv_per_token
            .checked_mul(profile.max_model_length)?
            .checked_add(state_per_sequence)?;
        let remaining = budget_bytes
            .saturating_sub(self.memory.expected_weight_bytes)
            .saturating_sub(self.memory.expected_engine_overhead_bytes);
        let sequences = remaining / per_sequence.max(1);
        Some(
            u32::try_from(sequences.min(u64::from(ENGINE_MAX_SEQUENCES)))
                .unwrap_or(ENGINE_MAX_SEQUENCES),
        )
    }
}

#[cfg(test)]
#[path = "reservation/tests.rs"]
mod tests;
