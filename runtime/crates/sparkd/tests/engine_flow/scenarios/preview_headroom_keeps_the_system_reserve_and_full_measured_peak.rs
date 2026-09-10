#[tokio::test]
async fn preview_headroom_keeps_the_system_reserve_and_full_measured_peak() {
    let (h, _, _, _) = harness(126_950_000_000).await;
    let mut recipe = RecipeFixture::example();
    recipe.profiles[0].expected_peak_bytes = 21_000_000_000;
    recipe.memory.minimum_system_reserve_bytes = 23_622_320_128;
    sparkd::guard::record_profile_peak(
        &h.state.database.as_ref().unwrap().lock(),
        recipe.id(),
        &recipe.profiles[0].id,
        96_950_000_000,
        &sparkd::guard::recipe_environment(&recipe),
    )
    .unwrap();
    let evidence = h
        .engine
        .admission_evidence(&recipe, &recipe.profiles[0], false)
        .unwrap();
    assert_eq!(evidence.required_memory_bytes, 96_950_000_000);
    assert_eq!(evidence.available_memory_bytes, 126_950_000_000);
    assert_eq!(evidence.system_reserve_bytes, 23_622_320_128);
    assert_eq!(evidence.expected_headroom_bytes, 6_377_679_872);
    assert!(evidence.decision.is_allowed());
    assert_eq!(
        evidence.available_memory_bytes,
        evidence.required_memory_bytes
            + evidence.system_reserve_bytes
            + evidence.expected_headroom_bytes,
    );
}
