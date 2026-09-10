//! Exercise signed loopback inference, proxy allowlists, cancellation, replacement, draining and verified stop with separate memory evidence.

const SIGNING_NODE_ID: uuid::Uuid = uuid::Uuid::from_u128(2);

use std::net::SocketAddr;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use p256::ecdsa::signature::Signer as _;
use p256::pkcs8::EncodePublicKey;
use rand::RngCore;
use serde_json::{Value, json};
use spark_core::identity::{FileIdentityStore, IdentityStore};
use spark_models::recipe::fixture::RecipeFixture;
use spark_models::{ModelRecipe, RemoteFile};
use spark_privd::backend::FakeBackend;
use spark_privd::workloads::{ObservedContainer, ObservedPort, ObservedWorkloads};
use spark_telemetry::{InferenceSnapshot, MemoryPressure, SystemMonitor, SystemSnapshot};
use sparkd::appliance_api::TelemetryConsentConfig;
use sparkd::auth;
use sparkd::clock::{ManualUtcClock, UtcClock, system_clock};
use sparkd::cluster::{ClusterService, MemberFacts, NoCollectiveTest, NoLinkProbe};
use sparkd::crypto::{base64url_encode, sha256_hex};
use sparkd::engine::EngineManager;
use sparkd::engine_backend::MockVllmBackend;
use sparkd::migration;
use sparkd::route::{router, router_with_request_timeout};
use sparkd::state::{AppState, RuntimeConfig};

/// The environment production measures the fixture recipe in; a peak stored under any other is not evidence.
fn fixture_environment() -> String {
    sparkd::guard::recipe_environment(&RecipeFixture::example())
}

include!("engine_flow/support/fixed_monitor.rs");

include!("engine_flow/support/harness.rs");

include!("engine_flow/scenarios/audit_automation_readiness.rs");
include!("engine_flow/scenarios/audit_guest_stream_budget.rs");

include!("engine_flow/support/empty_resolver.rs");

include!("engine_flow/support/unused_source.rs");

include!("engine_flow/support/fresh_device_key.rs");

include!("engine_flow/support/spki_der.rs");

include!("engine_flow/support/harness_with_clock.rs");

include!("engine_flow/support/harness_with_external_engine.rs");

include!("engine_flow/support/clustered_harness.rs");

include!("engine_flow/support/seed_degraded_cluster_recovery.rs");

include!("engine_flow/support/harness_with_policy.rs");

include!("engine_flow/support/fresh_nonce.rs");

include!("engine_flow/support/rfc3339_now.rs");

include!("engine_flow/support/signed_parts.rs");

include!("engine_flow/support/signed_json.rs");

include!("engine_flow/support/previewed_apply_body.rs");

include!("engine_flow/support/signed_json_with_idempotency.rs");

include!("engine_flow/scenarios/concurrent_duplicate_load_returns_one_durable_operation.rs");

include!("engine_flow/scenarios/one_preview_cannot_authorize_two_load_keys.rs");

include!(
    "engine_flow/scenarios/load_apply_requires_a_digest_without_poisoning_the_idempotency_key.rs"
);

include!(
    "engine_flow/scenarios/an_external_engine_blocks_takeover_but_allows_an_owned_model_download.rs"
);

include!(
    "engine_flow/scenarios/a_stopped_degraded_cluster_can_launch_an_exact_signed_single_node_recovery.rs"
);

include!(
    "engine_flow/scenarios/single_node_recovery_preview_goes_stale_if_cluster_recovers_before_apply.rs"
);

include!("engine_flow/scenarios/cluster_targeted_load_fails_closed_before_local_engine_launch.rs");

include!(
    "engine_flow/scenarios/standalone_load_carrying_a_cluster_id_reports_cluster_inference_unavailable.rs"
);

include!("engine_flow/scenarios/load_apply_rejects_a_changed_capacity_decision.rs");

include!("engine_flow/scenarios/load_apply_rejects_a_changed_active_model.rs");

include!("engine_flow/scenarios/active_model_removal_keeps_inventory_files_and_engine_evidence.rs");

include!("engine_flow/scenarios/removal_refuses_a_queued_load_before_engine_evidence_exists.rs");

include!("engine_flow/scenarios/load_requires_a_well_formed_idempotency_key.rs");

include!("engine_flow/scenarios/a_reused_load_key_with_a_different_signed_body_conflicts.rs");

include!("engine_flow/scenarios/repeated_synchronous_load_refusal_stays_non_mutating.rs");

include!("engine_flow/scenarios/duplicate_operation_cancel_replays_the_original_transition.rs");

include!("engine_flow/scenarios/concurrent_duplicate_install_starts_one_download.rs");

include!("engine_flow/scenarios/install_honours_typed_revision_and_credential_fields.rs");

include!("engine_flow/scenarios/exact_install_retry_replays_after_credential_revocation.rs");

include!("engine_flow/scenarios/signed_load_replays_after_app_state_restart.rs");

include!(
    "engine_flow/scenarios/restart_reconciliation_stops_a_persisted_engine_before_reporting_unloaded.rs"
);

include!(
    "engine_flow/scenarios/restart_reconciliation_recovers_adopted_container_without_stopping_it.rs"
);

include!("engine_flow/support/wait_terminal.rs");

include!(
    "engine_flow/scenarios/first_load_exposes_engine_image_preparation_before_container_start.rs"
);

include!("engine_flow/scenarios/load_exposes_health_check_while_readiness_probes_run.rs");

include!("engine_flow/scenarios/unload_exposes_the_real_container_stop_stage_and_progress.rs");

include!(
    "engine_flow/scenarios/ready_load_records_observed_profile_memory_for_future_admission.rs"
);

include!("engine_flow/support/load_model.rs");

include!("engine_flow/support/status_and_active_inference.rs");

include!("engine_flow/support/signed_event_stream.rs");
// Engine lifecycle and admission integration cases.

include!("engine_flow/scenarios/completed_engine_operation_event_is_durable_and_replayable.rs");

include!("engine_flow/scenarios/status_tracks_the_live_engine_through_load_and_failed_unload.rs");

include!("engine_flow/scenarios/full_lifecycle_load_chat_unload.rs");

include!("engine_flow/scenarios/non_streaming_chat_is_not_cut_off_by_the_general_route_timeout.rs");

include!("engine_flow/scenarios/stream_cancellation_stops_upstream_and_slot_is_released.rs");

include!("engine_flow/scenarios/port_is_not_reachable_from_lan_interfaces.rs");

include!("engine_flow/scenarios/unknown_upstream_paths_are_impossible.rs");

include!("engine_flow/scenarios/replacement_requires_explicit_request.rs");

include!("engine_flow/scenarios/replacement_refuses_to_launch_until_outgoing_memory_recovers.rs");

include!(
    "engine_flow/scenarios/replacement_uses_recovered_memory_and_records_the_post_stop_baseline.rs"
);

include!("engine_flow/scenarios/failed_replacement_restores_the_last_ready_engine.rs");

include!(
    "engine_flow/scenarios/replacement_stop_failure_keeps_the_existing_engine_without_relaunching.rs"
);

include!("engine_flow/scenarios/load_probes_the_port_the_backend_actually_bound.rs");

include!(
    "engine_flow/scenarios/unload_succeeds_when_the_container_is_gone_but_memory_has_not_returned.rs"
);

include!(
    "engine_flow/scenarios/unload_waits_for_memory_to_recover_within_the_configured_window.rs"
);

include!("engine_flow/scenarios/admission_rejects_insufficient_memory.rs");

include!("engine_flow/scenarios/uninstalled_model_is_rejected.rs");

include!("engine_flow/scenarios/capabilities_reports_dev_stub_truthfully_and_is_role_protected.rs");
include!(
    "engine_flow/scenarios/capabilities_name_the_cluster_sizes_the_coordinator_can_actually_form.rs"
);

// Exercise canonical admission and guard-driven engine stops.

include!("engine_flow/support/static_source.rs");

include!("engine_flow/support/guard_over.rs");

include!("engine_flow/scenarios/admission_blocks_unsafe_profiles.rs");

include!("engine_flow/scenarios/admission_blocks_while_pressure_is_active.rs");

include!("engine_flow/scenarios/guard_emergency_stops_the_loaded_engine_and_blocks_readmission.rs");

include!(
    "engine_flow/scenarios/guard_stop_owns_the_engine_transition_until_container_stop_finishes.rs"
);

include!("engine_flow/scenarios/usage_is_recorded_from_completions.rs");

include!("engine_flow/scenarios/usage_stops_when_consent_is_withdrawn_during_stream.rs");

include!("engine_flow/scenarios/a_refused_chat_body_never_moves_the_engine_counters.rs");

include!("engine_flow/scenarios/a_valid_chat_body_is_admitted_exactly_once.rs");

include!("engine_flow/scenarios/admission_checks_identity_before_it_counts.rs");

include!("engine_flow/scenarios/an_engine_swapped_after_parsing_refuses_the_admission.rs");

include!(
    "engine_flow/scenarios/catalogue_fit_uses_the_measured_engine_peak_that_load_preview_requires.rs"
);

include!(
    "engine_flow/scenarios/preview_headroom_keeps_the_system_reserve_and_full_measured_peak.rs"
);

include!(
    "engine_flow/scenarios/catalogue_fit_honors_a_larger_runtime_system_reserve_than_the_recipe.rs"
);

include!("engine_flow/scenarios/catalogue_replacement_fit_uses_the_same_baseline_as_preview.rs");

include!(
    "engine_flow/scenarios/fixed_target_history_keeps_safe_admission_refusals_and_completed_attempts.rs"
);

include!(
    "engine_flow/scenarios/fixed_target_history_cancel_closes_the_exact_live_proxy_and_replays_receipt.rs"
);

include!("engine_flow/scenarios/forced_unload_skips_active_request_drain.rs");

include!("engine_flow/scenarios/an_unload_that_does_not_reclaim_memory_says_so.rs");

include!("engine_flow/scenarios/a_typed_launch_rejection_records_its_code_on_the_operation.rs");

include!("engine_flow/scenarios/development_gateway.rs");
include!(
    "engine_flow/scenarios/load_preview_budgets_the_recipe_arithmetic_and_projects_what_fits_now.rs"
);

include!("engine_flow/scenarios/qwen_recipe_lifecycle.rs");
