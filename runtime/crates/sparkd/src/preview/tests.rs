use super::*;
use crate::clock::ManualUtcClock;

fn binding() -> PreviewBinding {
    PreviewBinding {
        target: PreviewTarget {
            node_id: uuid::Uuid::nil(),
            cluster_id: None,
        },
        recipe: None,
        evidence: PreviewEvidence {
            external_workload_id: None,
            external_workload_evidence_digest: None,
            external_workload_healthy: None,
            remote: None,
            install_state: None,
            installed_bytes: None,
            removable_bytes: None,
            download_bytes: None,
            locally_reusable_bytes: None,
            required_disk_bytes: None,
            disk_free_bytes: Some(10),
            expected_disk_free_after_bytes: None,
            required_memory_bytes: None,
            available_memory_bytes: Some(20),
            system_reserve_bytes: None,
            expected_memory_headroom_bytes: None,
            launch_memory: None,
            memory_pressure: Some("normal".into()),
            memory_admission: None,
            profile_failure_code: None,
            active_inference_available: true,
            engine_transitioning: false,
            active_engine: None,
            cluster_membership_available: false,
            cluster_membership_source: None,
            cluster: None,
        },
    }
}

fn draft(binding: PreviewBinding) -> PreviewDraft {
    PreviewDraft {
        action: "stop",
        action_key: action_key("stop", json!({ "force": false })),
        binding,
        consequences: PreviewConsequences::default(),
        blockers: Vec::new(),
        warnings: Vec::new(),
    }
}

fn load_draft(binding: PreviewBinding) -> PreviewDraft {
    PreviewDraft {
        action: "load",
        action_key: action_key("load", json!({ "profile": "test" })),
        binding,
        consequences: PreviewConsequences::default(),
        blockers: Vec::new(),
        warnings: Vec::new(),
    }
}

#[test]
fn changed_and_expired_evidence_fail_closed() {
    let now = OffsetDateTime::from_unix_timestamp(1_700_000_000).unwrap();
    let clock = Arc::new(ManualUtcClock::new(now));
    let service = PreviewService::new(clock.clone());
    let binding = binding();
    let baseline = load_draft(binding.clone());
    let preview = service.issue(&baseline).unwrap();
    let digest = preview["preview_digest"].as_str().unwrap();
    assert_eq!(service.validate(Some(digest), &baseline, "apply-a"), Ok(()));

    let mut changed = binding.clone();
    changed.evidence.available_memory_bytes = Some(19);
    assert_eq!(
        service.validate(Some(digest), &load_draft(changed.clone()), "apply-a"),
        Ok(())
    );

    changed.evidence.memory_admission = Some("deny_insufficient_memory".into());
    assert_eq!(
        service.validate(Some(digest), &load_draft(changed), "apply-a"),
        Err(PreviewValidationError::Stale)
    );

    clock.advance(PREVIEW_LIFETIME + time::Duration::seconds(1));
    assert_eq!(
        service.validate(Some(digest), &baseline, "apply-a"),
        Err(PreviewValidationError::Expired)
    );
}

#[test]
fn structural_cluster_changes_stale_but_member_order_does_not() {
    let now = OffsetDateTime::from_unix_timestamp(1_700_000_000).unwrap();
    let service = PreviewService::new(Arc::new(ManualUtcClock::new(now)));
    let mut original = binding();
    original.evidence.cluster_membership_available = true;
    original.evidence.cluster_membership_source = Some("runtime_cache".into());
    original.evidence.cluster = Some(PreviewClusterEvidence {
        cluster_id: Some(uuid::Uuid::nil().to_string()),
        state: "ready".into(),
        members: vec![
            PreviewClusterMember {
                node_id: "node-b".into(),
                role: "worker".into(),
                reachable: true,
                reachability_source: "runtime_cache".into(),
            },
            PreviewClusterMember {
                node_id: "node-a".into(),
                role: "head".into(),
                reachable: true,
                reachability_source: "runtime_cache".into(),
            },
        ],
    });
    let baseline = draft(original.clone());
    let preview = service.issue(&baseline).unwrap();
    let digest = preview["preview_digest"].as_str().unwrap();

    let mut reordered = original.clone();
    reordered
        .evidence
        .cluster
        .as_mut()
        .unwrap()
        .members
        .reverse();
    assert_eq!(
        service.validate(Some(digest), &draft(reordered), "apply-a"),
        Ok(())
    );

    let mut changed = original;
    changed.evidence.cluster.as_mut().unwrap().members[0].reachable = false;
    assert_eq!(
        service.validate(Some(digest), &draft(changed), "apply-a"),
        Err(PreviewValidationError::Stale)
    );
}

#[test]
fn an_accepted_preview_cannot_authorize_a_second_apply() {
    let now = OffsetDateTime::from_unix_timestamp(1_700_000_000).unwrap();
    let service = PreviewService::new(Arc::new(ManualUtcClock::new(now)));
    let baseline = draft(binding());
    let preview = service.issue(&baseline).unwrap();
    let digest = preview["preview_digest"].as_str().unwrap();
    assert_eq!(service.validate(Some(digest), &baseline, "apply-a"), Ok(()));
    assert_eq!(
        service.validate(Some(digest), &baseline, "apply-b"),
        Err(PreviewValidationError::AlreadyAccepted)
    );
}

/// §32.4: a memory refusal must be able to name a smaller context, not just ask for one.
#[test]
fn alternatives_rank_by_peak_exclude_the_refused_profile_and_stay_bounded() {
    use spark_models::recipe::Profile;
    let mut recipe = spark_models::recipe::fixture::RecipeFixture::example();
    let template = recipe.profiles[0].clone();
    let profile = |id: &str, length: u64, peak: u64| Profile {
        id: id.to_owned(),
        display_name: format!("Profile {id}"),
        max_model_length: length,
        expected_peak_bytes: peak,
        ..template.clone()
    };
    recipe.profiles = vec![
        profile("long-64k", 65_536, 143_000_000_000),
        profile("balanced-16k", 16_384, 101_000_000_000),
        profile("quantized-32k", 32_768, 116_000_000_000),
    ];

    let budget = 120_000_000_000_u64;
    let ranked = PreviewAlternativeProfile::admissible(&recipe, "long-64k", |candidate| {
        candidate.expected_peak_bytes <= budget
    });
    let names: Vec<&str> = ranked
        .iter()
        .map(|entry| entry.profile_id.as_str())
        .collect();
    assert_eq!(
        names,
        ["balanced-16k", "quantized-32k"],
        "smallest peak first so the client offers the safest alternative"
    );
    assert_eq!(ranked[0].max_model_length, 16_384);
    assert_eq!(ranked[0].display_name, "Profile balanced-16k");
    assert_eq!(ranked[0].expected_peak_bytes, 101_000_000_000);

    // The refused profile is never offered back, even when it would pass the predicate.
    let self_offer = PreviewAlternativeProfile::admissible(&recipe, "balanced-16k", |_| true);
    assert!(
        !self_offer
            .iter()
            .any(|entry| entry.profile_id == "balanced-16k")
    );

    // Nothing fits: an empty list is a real answer, not a missing one.
    assert!(PreviewAlternativeProfile::admissible(&recipe, "long-64k", |_| false).is_empty());

    // A recipe with more profiles than the contract's maxItems is truncated.
    recipe.profiles = (0..40)
        .map(|index| profile(&format!("p{index:02}"), 1024, 1_000 + index))
        .collect();
    let bounded = PreviewAlternativeProfile::admissible(&recipe, "p00", |_| true);
    assert_eq!(bounded.len(), 16);
    assert_eq!(
        bounded[0].profile_id, "p01",
        "the smallest survivors are kept"
    );
}

#[test]
fn launch_memory_flattens_into_the_evidence_and_stays_absent_without_arithmetic() {
    let mut binding = binding();
    let value = serde_json::to_value(&binding.evidence).unwrap();
    assert!(value.get("weight_bytes").is_none());
    assert!(value.get("max_context_now").is_none());
    binding.evidence.launch_memory = Some(PreviewLaunchMemory {
        weight_bytes: 24_000_000_000,
        kv_cache_bytes: 12_884_901_888,
        state_bytes: 402_653_184,
        engine_overhead_bytes: 8_589_934_592,
        max_context_now: 1_048_576,
        max_sequences_now: 64,
    });
    let value = serde_json::to_value(&binding.evidence).unwrap();
    assert_eq!(value["weight_bytes"], 24_000_000_000_u64);
    assert_eq!(value["kv_cache_bytes"], 12_884_901_888_u64);
    assert_eq!(value["state_bytes"], 402_653_184_u64);
    assert_eq!(value["engine_overhead_bytes"], 8_589_934_592_u64);
    assert_eq!(value["max_context_now"], 1_048_576_u64);
    assert_eq!(value["max_sequences_now"], 64_u64);
    assert!(
        value.get("launch_memory").is_none(),
        "the breakdown is flat on the wire"
    );
}
