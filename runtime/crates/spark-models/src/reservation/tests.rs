use super::*;
use crate::recipe::fixture::RecipeFixture;

const WEIGHTS: u64 = 24_000_000_000;
const OVERHEAD: u64 = 8_589_934_592;
const KV_PER_TOKEN: u64 = 3072;
const STATE_PER_SEQUENCE: u64 = 25_165_824;
const RESERVE: u64 = 23_622_320_128;

fn nemotron_like(context: u64, sequences: u32) -> ModelRecipe {
    let mut recipe = RecipeFixture::example();
    recipe.memory.expected_weight_bytes = WEIGHTS;
    recipe.memory.expected_engine_overhead_bytes = OVERHEAD;
    recipe.memory.kv_cache_bytes_per_token = Some(KV_PER_TOKEN);
    recipe.memory.state_bytes_per_sequence = Some(STATE_PER_SEQUENCE);
    recipe.profiles[0].max_model_length = context;
    recipe.profiles[0].max_sequences = sequences;
    recipe.profiles[0].expected_peak_bytes = recipe
        .reservation(&recipe.profiles[0])
        .unwrap()
        .total_bytes();
    recipe.signature.value = "dGVzdA".into();
    recipe
}

#[test]
fn a_256k_by_16_profile_derives_its_four_parts_and_total() {
    let recipe = nemotron_like(262_144, 16);
    let reservation = recipe.reservation(&recipe.profiles[0]).unwrap();
    assert_eq!(reservation.weight_bytes, WEIGHTS);
    assert_eq!(reservation.kv_cache_bytes, 12_884_901_888);
    assert_eq!(reservation.state_bytes, 402_653_184);
    assert_eq!(reservation.engine_overhead_bytes, OVERHEAD);
    assert_eq!(reservation.total_bytes(), 45_877_489_664);
    assert_eq!(reservation.engine_cache_bytes(), 13_287_555_072);
    assert_eq!(
        recipe.profile_reservation_bytes(&recipe.profiles[0]),
        45_877_489_664
    );
    assert!(recipe.validate().is_ok());
}

#[test]
fn one_million_by_four_and_64k_by_32_follow_the_same_arithmetic() {
    let long = nemotron_like(1_048_576, 4);
    assert_eq!(
        long.profile_reservation_bytes(&long.profiles[0]),
        45_575_499_776
    );
    let agent = nemotron_like(65_536, 32);
    let reservation = agent.reservation(&agent.profiles[0]).unwrap();
    assert_eq!(reservation.kv_cache_bytes, 6_442_450_944);
    assert_eq!(reservation.state_bytes, 805_306_368);
    assert_eq!(reservation.total_bytes(), 39_837_691_904);
}

#[test]
fn an_older_recipe_without_arithmetic_keeps_its_declared_peak() {
    let recipe = RecipeFixture::example();
    assert!(recipe.reservation(&recipe.profiles[0]).is_none());
    assert_eq!(
        recipe.profile_reservation_bytes(&recipe.profiles[0]),
        101_000_000_000
    );
    assert!(
        recipe
            .max_context_that_fits(&recipe.profiles[0], 130_000_000_000)
            .is_none()
    );
    assert!(
        recipe
            .max_sequences_that_fit(&recipe.profiles[0], 130_000_000_000)
            .is_none()
    );
}

#[test]
fn a_declared_peak_below_the_arithmetic_is_refused() {
    let mut recipe = nemotron_like(262_144, 16);
    recipe.profiles[0].expected_peak_bytes = 40_000_000_000;
    assert_eq!(
        recipe.validate(),
        Err(RecipeError::PeakDisagreesWithArithmetic {
            profile: "balanced-16k".into(),
            declared: 40_000_000_000,
            derived: 45_877_489_664,
        })
    );
    // A larger claim is refused too: the recipe's own numbers are the only truth it may state.
    recipe.profiles[0].expected_peak_bytes = 96_000_000_000;
    assert!(matches!(
        recipe.validate(),
        Err(RecipeError::PeakDisagreesWithArithmetic { .. })
    ));
}

#[test]
fn half_declared_zero_and_overflowing_arithmetic_are_refused() {
    let mut half = nemotron_like(262_144, 16);
    half.memory.state_bytes_per_sequence = None;
    assert!(matches!(
        half.validate(),
        Err(RecipeError::InvalidMemoryArithmetic(_))
    ));
    let mut zero = nemotron_like(262_144, 16);
    zero.memory.kv_cache_bytes_per_token = Some(0);
    assert!(matches!(
        zero.validate(),
        Err(RecipeError::InvalidMemoryArithmetic(_))
    ));
    let mut overflow = nemotron_like(1_048_576, 64);
    overflow.memory.kv_cache_bytes_per_token = Some(u64::MAX / 1024);
    assert!(overflow.reservation(&overflow.profiles[0]).is_none());
    assert!(matches!(
        overflow.validate(),
        Err(RecipeError::InvalidMemoryArithmetic(_))
    ));
}

#[test]
fn the_largest_context_that_fits_now_is_a_whole_block_count_capped_at_the_recipe_ceiling() {
    let recipe = nemotron_like(262_144, 16);
    let budget = 123_540_000_000 - RESERVE;
    // 66,925,092,096 bytes over 49,152 bytes per token is 1,361,594 tokens; the recipe's own ceiling is 262,144.
    assert_eq!(
        recipe.max_context_that_fits(&recipe.profiles[0], budget),
        Some(262_144)
    );
    let mut wider = recipe.clone();
    wider
        .profiles
        .push(nemotron_like(1_048_576, 4).profiles[0].clone());
    assert_eq!(
        wider.max_context_that_fits(&wider.profiles[0], budget),
        Some(1_048_576)
    );
    // With 60 GB available, 3,385,092,096 cache bytes over 49,152 per token is 68,869 tokens, rounded down to 65,536.
    assert_eq!(
        recipe.max_context_that_fits(&recipe.profiles[0], 60_000_000_000 - RESERVE),
        Some(65_536)
    );
    assert_eq!(
        recipe.max_context_that_fits(&recipe.profiles[0], WEIGHTS),
        Some(0)
    );
}

#[test]
fn the_requests_that_fit_now_use_the_full_profile_context_and_stop_at_the_engine_limit() {
    let recipe = nemotron_like(262_144, 16);
    let budget = 123_540_000_000 - RESERVE;
    // 67,327,745,280 bytes over 830,472,192 bytes per request is 81, above the 64-request engine policy.
    assert_eq!(
        recipe.max_sequences_that_fit(&recipe.profiles[0], budget),
        Some(64)
    );
    // With 60 GB available, 3,787,745,280 bytes over 830,472,192 per request admits 4 full-context requests.
    assert_eq!(
        recipe.max_sequences_that_fit(&recipe.profiles[0], 60_000_000_000 - RESERVE),
        Some(4)
    );
    assert_eq!(
        recipe.max_sequences_that_fit(&recipe.profiles[0], WEIGHTS),
        Some(0)
    );
}

#[test]
fn every_shipped_nemotron_profile_declares_exactly_what_its_arithmetic_derives() {
    let recipe: ModelRecipe = serde_json::from_str(include_str!(
        "../../../../../recipes/nvidia-nemotron-3.5-lightning-30b-a3b-nvfp4.json"
    ))
    .unwrap();
    assert!(recipe.validate().is_ok());
    let totals: Vec<(String, u64)> = recipe
        .profiles
        .iter()
        .map(|profile| {
            (
                profile.id.clone(),
                recipe.profile_reservation_bytes(profile),
            )
        })
        .collect();
    assert_eq!(
        totals,
        vec![
            ("agent-256k".to_owned(), 47_622_320_128),
            ("long-1m".to_owned(), 46_011_707_392),
            ("agent-64k".to_owned(), 43_327_352_832),
        ]
    );
    let default = &recipe.profiles[0];
    assert_eq!(
        (default.max_model_length, default.max_sequences),
        (262_144, 16)
    );
}

#[test]
fn the_utilisation_share_follows_the_reservation_within_the_helper_policy() {
    let recipe: ModelRecipe = serde_json::from_str(include_str!(
        "../../../../../recipes/nvidia-nemotron-3.5-lightning-30b-a3b-nvfp4.json"
    ))
    .unwrap();
    let total = 128_000_000_000;
    let agent = &recipe.profiles[0];
    // 47,622,320,128 of 128,000,000,000 is 37.2%, below the floor the helper accepts.
    assert_eq!(recipe.launch_utilisation_milli(agent, total), 400);
    // A tighter host raises the share to what the launch needs, rounded up to the next thousandth.
    assert_eq!(recipe.launch_utilisation_milli(agent, 64_000_000_000), 745);
    // A launch larger than the device is capped so the flag stays inside the helper's policy.
    assert_eq!(recipe.launch_utilisation_milli(agent, 40_000_000_000), 900);
    // Without a device total or without arithmetic the profile's declared share stands.
    assert_eq!(recipe.launch_utilisation_milli(agent, 0), 700);
    let fixed = RecipeFixture::example();
    assert!(fixed.memory.kv_cache_bytes_per_token.is_none());
    assert_eq!(
        fixed.launch_utilisation_milli(&fixed.profiles[0], total),
        720
    );
}

#[test]
fn nemotron_cache_budget_holds_every_full_context_with_aligned_mamba_pages() {
    let recipe: ModelRecipe = serde_json::from_str(include_str!(
        "../../../../../recipes/nvidia-nemotron-3.5-lightning-30b-a3b-nvfp4.json"
    ))
    .unwrap();
    // Pinned vLLM 0.28.0 packs six attention layers and 23 Mamba layers into four state groups, using two 4,176-token blocks per group in align mode.
    let pool_page_bytes = 4_176 * 512 * 6;
    for profile in &recipe.profiles {
        let blocks_per_request = profile.max_model_length.div_ceil(4_176) + 4 * 2;
        let required =
            (blocks_per_request * u64::from(profile.max_sequences) + 1) * pool_page_bytes; // Include the shared pool's null block.
        assert!(
            recipe.reservation(profile).unwrap().engine_cache_bytes() >= required,
            "{} cannot hold its advertised full-context requests",
            profile.id
        );
    }
}
