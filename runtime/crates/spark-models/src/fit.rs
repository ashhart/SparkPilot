//! Fit-state estimation from static recipe memory (§29.4, §32).

use crate::recipe::ModelRecipe;

/// User-visible fit categories (mirrors the OpenAPI `Model.fit` enum).
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum FitState {
    Ready,
    Fits,
    FitsAfterUnload,
    SmallerProfileRequired,
    ClusterRequired,
    Incompatible,
    Unknown,
}

/// Estimate fit from pre-reserve availability plus known reclaimable engine memory; use zero reclaimable bytes when residency is unknown.
pub fn compute_fit(
    recipe: &ModelRecipe,
    installed: bool,
    available_bytes: u64,
    system_reserve_bytes: u64,
    reclaimable_bytes: u64,
    cluster_available: bool,
) -> FitState {
    let budget = available_bytes.saturating_sub(system_reserve_bytes);
    // Add reclaimed memory before subtracting reserve so recovery first covers any existing reserve deficit.
    let replacement_budget = available_bytes
        .saturating_add(reclaimable_bytes)
        .saturating_sub(system_reserve_bytes);
    let smallest_peak = recipe.profiles.iter().map(|p| p.expected_peak_bytes).min();

    match smallest_peak {
        None => FitState::Incompatible,
        Some(peak) if peak <= budget && installed => FitState::Ready,
        Some(peak) if peak <= budget => FitState::Fits,
        // Prefer stopping a resident model on one Spark before suggesting a cluster (ADR-005).
        Some(peak) if peak <= replacement_budget => FitState::FitsAfterUnload,
        Some(_) if cluster_available => FitState::ClusterRequired,
        Some(_) => FitState::SmallerProfileRequired,
    }
}

/// The recommended profile (smallest that fits within the budget).
pub fn recommended_profile(
    recipe: &ModelRecipe,
    available_bytes: u64,
    system_reserve_bytes: u64,
) -> Option<&crate::recipe::Profile> {
    let budget = available_bytes.saturating_sub(system_reserve_bytes);
    recipe
        .profiles
        .iter()
        .filter(|p| p.expected_peak_bytes <= budget)
        .min_by_key(|p| p.expected_peak_bytes)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::recipe::fixture::RecipeFixture;

    #[test]
    fn fits_when_headroom_covers_smallest_profile() {
        let recipe = RecipeFixture::example();
        // 128 GiB total, 26.8 available, 22 reserve -> ~4.8 GiB budget.
        let fit = compute_fit(&recipe, false, 26_843_700_000, 23_623_220_128, 0, false);
        assert_eq!(fit, FitState::SmallerProfileRequired); // smallest peak is 101 GB
        let fit = compute_fit(&recipe, false, 130_000_000_000, 23_623_220_128, 0, false);
        assert_eq!(fit, FitState::Fits);
    }

    #[test]
    fn installed_model_reports_ready() {
        let recipe = RecipeFixture::example();
        let fit = compute_fit(&recipe, true, 130_000_000_000, 23_623_220_128, 0, false);
        assert_eq!(fit, FitState::Ready);
    }

    #[test]
    fn cluster_flag_promotes_to_cluster_required() {
        let recipe = RecipeFixture::example();
        let fit = compute_fit(&recipe, false, 26_843_700_000, 23_623_220_128, 0, true);
        assert_eq!(fit, FitState::ClusterRequired);
    }

    #[test]
    fn broken_recipe_is_incompatible() {
        let mut recipe = RecipeFixture::example();
        recipe.profiles.clear();
        assert_eq!(
            compute_fit(&recipe, false, 130_000_000_000, 23_623_220_128, 0, false),
            FitState::Incompatible
        );
    }

    #[test]
    fn memory_an_active_engine_would_release_reports_fits_after_unload() {
        let recipe = RecipeFixture::example();
        // A node with about 3.2 GiB budget and 110 GB reclaimable memory should report fits-after-unload.
        let fit = compute_fit(
            &recipe,
            false,
            26_843_700_000,
            23_623_220_128,
            110_000_000_000,
            false,
        );
        assert_eq!(fit, FitState::FitsAfterUnload);
    }

    #[test]
    fn reclaimable_memory_that_still_falls_short_stays_smaller_profile_required() {
        let recipe = RecipeFixture::example();
        // Only 1 GB would come back; the smallest profile needs 101 GB.
        let fit = compute_fit(
            &recipe,
            false,
            26_843_700_000,
            23_623_220_128,
            1_000_000_000,
            false,
        );
        assert_eq!(fit, FitState::SmallerProfileRequired);
    }

    #[test]
    fn stopping_the_active_model_is_preferred_over_recruiting_a_cluster() {
        // Prefer a viable single-Spark replacement over requiring another Spark.
        let recipe = RecipeFixture::example();
        let fit = compute_fit(
            &recipe,
            false,
            26_843_700_000,
            23_623_220_128,
            110_000_000_000,
            true,
        );
        assert_eq!(fit, FitState::FitsAfterUnload);
    }

    #[test]
    fn replacement_refills_a_depleted_system_reserve_before_claiming_fit() {
        let mut recipe = RecipeFixture::example();
        recipe.profiles[0].expected_peak_bytes = 25_000_000_000;
        // Ten GB free plus thirty reclaimed minus twenty-two reserve leaves eighteen GB.
        assert_eq!(
            compute_fit(
                &recipe,
                true,
                10_000_000_000,
                22_000_000_000,
                30_000_000_000,
                false
            ),
            FitState::SmallerProfileRequired,
        );
    }

    #[test]
    fn recommended_profile_is_smallest_fitting() {
        let recipe = RecipeFixture::example();
        let profile = recommended_profile(&recipe, 130_000_000_000, 23_623_220_128);
        assert_eq!(profile.map(|p| p.id.as_str()), Some("balanced-16k"));
    }

    #[test]
    fn shipping_default_preset_fits_the_reported_idle_spark_without_spending_system_reserve() {
        let mut recipe: ModelRecipe = serde_json::from_str(include_str!(
            "../../../../recipes/nvidia-nemotron-3.5-lightning-30b-a3b-nvfp4.json"
        ))
        .unwrap();
        recipe.profiles.retain(|profile| profile.id == "agent-256k");
        assert_eq!(recipe.profiles.len(), 1);
        let profile = &recipe.profiles[0];
        assert_eq!(profile.max_model_length, 262_144);
        assert_eq!(profile.max_sequences, 16);
        // The declared peak is the recipe's own arithmetic, not a share of unified memory.
        assert_eq!(profile.expected_peak_bytes, 47_622_320_128);
        let reserve = recipe.memory.minimum_system_reserve_bytes;
        assert!(reserve >= 22 * 1024 * 1024 * 1024);
        assert_eq!(
            compute_fit(&recipe, true, 123_540_000_000, reserve, 0, false),
            FitState::Ready,
            "The advertised preset must fit the owner's idle Spark with its reserve intact"
        );
        // Still refuse under real pressure; this is a recipe correction, not a guard bypass.
        assert_eq!(
            compute_fit(
                &recipe,
                true,
                profile.expected_peak_bytes + reserve - 1,
                reserve,
                0,
                false
            ),
            FitState::SmallerProfileRequired
        );
    }
}
