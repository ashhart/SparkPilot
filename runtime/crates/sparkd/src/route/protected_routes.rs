use super::*;

pub(super) fn identity() -> Router<AppState> {
    Router::new()
        .route("/api/v1/identity", get(handlers::identity))
        .route("/api/v1/status", get(handlers::status))
        .route("/api/v1/capabilities", get(handlers::capabilities))
        .route("/api/v1/devices", get(handlers::list_devices))
        .route(
            "/api/v1/devices/self/presence-key",
            post(handlers::enroll_presence_key),
        )
        .route(
            "/api/v1/devices/{device_id}",
            axum::routing::patch(handlers::update_device).delete(handlers::revoke_device),
        )
        .route(
            "/api/v1/presence/challenge",
            post(handlers::presence_challenge),
        )
}

pub(super) fn observation() -> Router<AppState> {
    Router::new()
        .route("/api/v1/telemetry", get(telemetry_api::get_telemetry))
        .route(
            "/api/v1/telemetry/history",
            get(telemetry_api::get_telemetry_history),
        )
        .route("/api/v1/diagnostics", get(diagnostics_api::get_catalogue))
        .route("/api/v1/diagnostics/export", post(diagnostics_api::export))
}

pub(super) fn workloads() -> Router<AppState> {
    Router::new()
        .route("/api/v1/workloads", get(workload_api::list_workloads))
        .route(
            "/api/v1/workloads/{workload_id}/adoption/preview",
            post(workload_adoption::preview_adoption),
        )
        .route(
            "/api/v1/workloads/{workload_id}/adopt",
            post(workload_adoption::adopt),
        )
        .route(
            "/api/v1/workloads/{workload_id}/relinquish/preview",
            post(workload_adoption::preview_relinquish),
        )
        .route(
            "/api/v1/workloads/{workload_id}/relinquish",
            post(workload_adoption::relinquish),
        )
}

pub(super) fn network() -> Router<AppState> {
    Router::new()
        .route(
            "/api/v1/network/interfaces",
            get(network_api::get_interfaces),
        )
        .route(
            "/api/v1/network/wifi",
            get(appliance_api::get_wifi_networks).post(appliance_api::connect_wifi),
        )
        .route(
            "/api/v1/network/wifi/forget",
            post(appliance_api::forget_wifi),
        )
        .route(
            "/api/v1/network/ethernet/ipv4",
            post(appliance_api::configure_lan_ipv4),
        )
        .route(
            "/api/v1/network/changes/{configuration_id}/confirm",
            post(appliance_api::confirm_network_change),
        )
        .route(
            "/api/v1/network/changes/{configuration_id}/rollback",
            post(appliance_api::rollback_network_change),
        )
        .route("/api/v1/network", get(network_api::get_network_status))
        .route(
            "/api/v1/network/direct-profile",
            post(appliance_api::configure_direct_ethernet),
        )
        .route(
            "/api/v1/network/travel-ap",
            post(appliance_api::configure_travel_access_point),
        )
}

pub(super) fn settings() -> Router<AppState> {
    Router::new()
        .route("/api/v1/settings", get(appliance_api::get_settings))
        .route(
            "/api/v1/settings/memory-guard",
            post(appliance_api::update_memory_guard),
        )
        .route(
            "/api/v1/settings/model-idle",
            post(appliance_api::update_model_idle_policy),
        )
        .route(
            "/api/v1/settings/telemetry",
            post(appliance_api::update_telemetry_consent),
        )
}

pub(super) fn automations() -> Router<AppState> {
    Router::new()
        .route(
            "/api/v1/automations",
            get(automations_api::list_automations).post(automations_api::create_automation),
        )
        .route(
            "/api/v1/automations/{id}",
            axum::routing::patch(automations_api::update_automation)
                .delete(automations_api::delete_automation),
        )
        .route(
            "/api/v1/automations/{id}/run",
            post(automations_api::runs::run_automation),
        )
        .route(
            "/api/v1/automations/{id}/runs",
            get(automations_api::runs::list_automation_runs),
        )
        .route(
            "/api/v1/web/settings",
            get(automations_api::web_settings::get_web_access_settings)
                .put(automations_api::web_settings::set_web_access_settings),
        )
        .route(
            "/api/v1/web/answer",
            post(automations_api::web_answer::create_web_answer),
        )
}

pub(super) fn catalogue() -> Router<AppState> {
    Router::new()
        .route("/api/v1/catalogue", get(catalogue_api::catalogue_status))
        .route(
            "/api/v1/catalogue/refresh/preview",
            post(catalogue_api::preview_catalogue_refresh),
        )
        .route(
            "/api/v1/catalogue/refresh",
            post(catalogue_api::refresh_catalogue),
        )
}

pub(super) fn services() -> Router<AppState> {
    Router::new()
        .route("/api/v1/services", get(service_api::list_services))
        .route("/api/v1/services/kokoro", get(crate::speech_api::status))
        .route(
            "/api/v1/services/kokoro/enable",
            post(crate::speech_api::enable),
        )
        .route(
            "/api/v1/services/kokoro/disable",
            post(crate::speech_api::disable),
        )
        .route(
            "/api/v1/services/kokoro/install",
            post(crate::speech_api::install),
        )
        .route(
            "/api/v1/services/kokoro/update",
            post(crate::speech_api::update),
        )
        .route(
            "/api/v1/services/kokoro/remove",
            post(crate::speech_api::remove),
        )
        .route(
            "/api/v1/services/open-webui",
            get(service_api::open_webui_status),
        )
        .route(
            "/api/v1/services/open-webui/install",
            post(service_api::install_open_webui),
        )
        .route(
            "/api/v1/services/open-webui/update",
            post(service_api::update_open_webui),
        )
        .route(
            "/api/v1/services/open-webui/repair",
            post(service_api::repair_open_webui),
        )
        .route(
            "/api/v1/services/open-webui/remove",
            post(service_api::remove_open_webui),
        )
        .route(
            "/api/v1/services/open-webui/access",
            post(service_api::open_webui_access),
        )
}

pub(super) fn pairing() -> Router<AppState> {
    Router::new().route(
        "/api/v1/pairing/invitations",
        post(handlers::create_invitation),
    )
}

pub(super) fn shared_access() -> Router<AppState> {
    Router::new()
        .route(
            "/api/v1/shared-access",
            get(crate::shared_access_api::list_shared_access),
        )
        .route(
            "/api/v1/shared-access/self",
            get(crate::shared_access_api::own_shared_access),
        )
        .route(
            "/api/v1/shared-access/invitations",
            post(crate::shared_access_api::create_shared_access_invitation),
        )
        .route(
            "/api/v1/shared-access/{deviceId}",
            axum::routing::patch(crate::shared_access_api::update_shared_access)
                .delete(crate::shared_access_api::revoke_shared_access),
        )
}

pub(super) fn models() -> Router<AppState> {
    Router::new()
        .route("/api/v1/models", get(models::list_models))
        .route(
            "/api/v1/models/{model_id}",
            get(models::get_model).delete(models::remove_model),
        )
        .route(
            "/api/v1/models/{model_id}/remove/preview",
            post(models::preview_remove_model),
        )
        .route(
            "/api/v1/models/{model_id}/install",
            post(download_api::install_model),
        )
        .route(
            "/api/v1/models/{model_id}/install/preview",
            post(download_api::preview_install_model),
        )
        .route(
            "/api/v1/models/{model_id}/profiles/{profile_id}/re-enable/preview",
            post(profile_api::preview_reenable_model_profile),
        )
        .route(
            "/api/v1/models/{model_id}/profiles/{profile_id}/re-enable",
            post(profile_api::reenable_model_profile),
        )
        .route(
            "/api/v1/models/import",
            post(models::import_unverified_model),
        )
}

pub(super) fn activity() -> Router<AppState> {
    Router::new()
        .route("/api/v1/operations", get(download_api::list_operations))
        .route(
            "/api/v1/operations/{operation_id}",
            get(download_api::get_operation),
        )
        .route(
            "/api/v1/operations/{operation_id}/cancel",
            post(download_api::cancel_operation),
        )
        .route("/api/v1/events", get(download_api::stream_events))
}

pub(super) fn cluster() -> Router<AppState> {
    Router::new()
        .route("/api/v1/cluster", get(cluster_api::get_cluster))
        .route(
            "/api/v1/cluster/descriptor",
            get(cluster_api::get_cluster_descriptor),
        )
        .route(
            "/api/v1/cluster/grants",
            get(cluster_api::get_cluster_grants),
        )
        .route(
            "/api/v1/cluster/import/preview",
            post(cluster_api::preview_external_cluster_import),
        )
        .route("/api/v1/cluster/create", post(cluster_api::create_cluster))
        .route(
            "/api/v1/cluster/validate",
            post(cluster_api::validate_cluster),
        )
}

pub(super) fn fabric() -> Router<AppState> {
    Router::new().route("/api/v1/fabric", get(cluster_api::get_fabric))
}

pub(super) fn remote() -> Router<AppState> {
    Router::new()
        .route("/api/v1/remote", get(remote_api::get_remote_status))
        .route(
            "/api/v1/remote/refresh",
            post(remote_api::refresh_remote_status),
        )
        .route(
            "/api/v1/remote/overlay/setup",
            get(remote_api::get_overlay_setup),
        )
        .route(
            "/api/v1/remote/overlay/preferences",
            get(remote_api::get_overlay_preferences)
                .post(remote_api::configure_overlay_preferences),
        )
        .route(
            "/api/v1/remote/enable/preview",
            post(remote_api::preview_enable_remote_access),
        )
        .route(
            "/api/v1/remote/enable",
            post(remote_api::enable_remote_access),
        )
        .route(
            "/api/v1/remote/disable/preview",
            post(remote_api::preview_disable_remote_access),
        )
        .route(
            "/api/v1/remote/disable",
            post(remote_api::disable_remote_access),
        )
}

pub(super) fn power() -> Router<AppState> {
    Router::new()
        .route("/api/v1/power/reboot", post(power_api::reboot))
        .route("/api/v1/power/shutdown", post(power_api::shutdown))
}

pub(super) fn system() -> Router<AppState> {
    Router::new()
        .route("/api/v1/system/hostname", post(system_api::set_hostname))
        .route(
            "/api/v1/system/bluetooth",
            post(appliance_api::configure_bluetooth),
        )
        .route(
            "/api/v1/system/power-profile",
            post(appliance_api::set_power_profile),
        )
        .route(
            "/api/v1/system/updates",
            get(appliance_api::get_software_updates).post(appliance_api::install_software_updates),
        )
        .route(
            "/api/v1/system/updates/check",
            post(appliance_api::refresh_software_updates),
        )
        .route(
            "/api/v1/system/time",
            post(appliance_api::configure_system_time),
        )
}

pub(super) fn storage() -> Router<AppState> {
    Router::new()
        .route("/api/v1/storage", get(appliance_api::get_storage))
        .route(
            "/api/v1/storage/cleanup",
            post(appliance_api::clean_storage),
        )
}

pub(super) fn credentials() -> Router<AppState> {
    Router::new()
        .route(
            "/api/v1/credentials",
            get(download_api::list_credentials).post(download_api::add_credential),
        )
        .route(
            "/api/v1/credentials/{credential_id}",
            axum::routing::delete(download_api::revoke_credential),
        )
}

pub(super) fn inference() -> Router<AppState> {
    Router::new()
        .route("/api/v1/inference/load", post(engine_api::load_inference))
        .route(
            "/api/v1/inference/warmups",
            get(crate::warmup_api::list_warmups).post(crate::warmup_api::create_warmup),
        )
        .route(
            "/api/v1/inference/warmups/preview",
            post(crate::warmup_api::preview_warmup),
        )
        .route(
            "/api/v1/inference/warmups/{id}/disable",
            post(crate::warmup_api::disable_warmup),
        )
        .route(
            "/api/v1/inference/router-identity",
            get(crate::pool_router_api::read).post(crate::pool_router_api::prepare),
        )
        .route(
            "/api/v1/inference/router-peers",
            get(crate::pool_router_api::peers),
        )
        .route(
            "/api/v1/inference/router-enrollments/challenge",
            post(crate::pool_router_api::challenge),
        )
        .route(
            "/api/v1/inference/router-identity/proof",
            post(crate::pool_router_api::proof),
        )
        .route(
            "/api/v1/inference/router-enrollments/{challenge_id}/apply",
            post(crate::pool_router_api::apply),
        )
        .route(
            "/api/v1/inference/router-principals/{principal_id}/revoke",
            post(crate::pool_router_api::revoke),
        )
        .route("/api/v1/inference/pools", get(crate::pool_api::list))
        .route(
            "/api/v1/inference/pools/preview",
            post(crate::pool_api::preview),
        )
        .route(
            "/api/v1/inference/pools/apply",
            post(crate::pool_api::apply),
        )
        .route(
            "/api/v1/inference/router-grants",
            post(crate::pool_api::grant),
        )
        .route(
            "/api/v1/inference/router-grants/{grant_id}/revoke",
            post(crate::pool_api::revoke),
        )
        .route(
            "/api/v1/inference/node-capabilities",
            get(crate::pool_api::capabilities),
        )
        .route(
            "/api/v1/inference/reservations",
            post(crate::pool_api::reserve),
        )
        .route(
            "/api/v1/inference/reservations/{reservation_id}",
            get(crate::pool_api::status),
        )
        .route(
            "/api/v1/inference/reservations/{reservation_id}/cancel",
            post(crate::pool_api::cancel),
        )
        .route(
            "/api/v1/inference/reservations/{reservation_id}/execute",
            post(crate::pool_api::execute),
        )
        .route(
            "/api/v1/inference/requests",
            get(crate::request_history::list).delete(crate::request_history::clear),
        )
        .route(
            "/api/v1/inference/requests/{attempt_id}/cancel",
            post(crate::request_history::cancel),
        )
        .route(
            "/api/v1/inference/load/preview",
            post(engine_api::preview_load_inference),
        )
        .route(
            "/api/v1/inference/unload",
            post(engine_api::unload_inference),
        )
        .route(
            "/api/v1/inference/unload/preview",
            post(engine_api::preview_unload_inference),
        )
        .route(
            "/api/v1/inference/active",
            get(engine_api::active_inference),
        )
        // Queue durable analyses for operation lookup instead of keeping generation on the HTTP request.
        .route(
            "/api/v1/inference/analyses",
            post(analysis_api::start_analysis),
        )
        .route("/v1/models", get(engine_api::openai_models))
}

pub(super) fn build_workers() -> Router<AppState> {
    Router::new()
        .route(
            "/api/v1/build_workers",
            get(build_api::list_workers).post(build_api::register_worker),
        )
        .route(
            "/api/v1/build_workers/{worker_id}/heartbeat",
            post(build_api::heartbeat_worker),
        )
        .route(
            "/api/v1/build_workers/{worker_id}/claims",
            post(build_api::claim_build),
        )
}

pub(super) fn builds() -> Router<AppState> {
    Router::new()
        .route("/api/v1/builds", post(build_api::submit_build))
        .route("/api/v1/builds/{build_id}", get(build_api::get_build))
        .route(
            "/api/v1/builds/{build_id}/lease",
            post(build_api::renew_claim),
        )
        .route(
            "/api/v1/builds/{build_id}/artifacts/{artifact_id}",
            get(build_api::get_artifact).put(build_api::upload_artifact),
        )
        .route(
            "/api/v1/builds/{build_id}/result",
            post(build_api::report_result),
        )
}

pub(super) fn projects() -> Router<AppState> {
    Router::new()
        .route(
            "/api/v1/development/preparation",
            get(project_api::development_preparation).post(project_api::prepare_development),
        )
        .route(
            "/api/v1/projects",
            get(project_api::list_projects).post(project_api::create_project),
        )
        .route(
            "/api/v1/projects/{projectId}",
            get(project_api::get_project).delete(project_api::delete_project),
        )
        .route(
            "/api/v1/projects/{projectId}/files",
            get(project_api::list_files),
        )
        .route(
            "/api/v1/projects/{projectId}/files/{*path}",
            get(project_api::read_file).put(project_api::save_file),
        )
        .route(
            "/api/v1/projects/{projectId}/terminals",
            post(project_api::create_terminal),
        )
        .route(
            "/api/v1/projects/{projectId}/terminals/{terminalId}/ws",
            get(project_api::attach_terminal),
        )
        .route(
            "/api/v1/projects/{projectId}/terminals/{terminalId}",
            get(project_api::terminal_state).delete(project_api::close_terminal),
        )
        .route(
            "/api/v1/projects/{projectId}/preview/{port}/{*path}",
            get(project_api::preview_asset),
        )
        .route(
            "/api/v1/projects/{projectId}/agents",
            post(agent_api::start_agent),
        )
        .route(
            "/api/v1/projects/{projectId}/changes",
            get(agent_api::list_changes),
        )
        .route(
            "/api/v1/projects/{projectId}/changes/{changeId}/approve",
            post(agent_api::approve_change),
        )
        .route(
            "/api/v1/projects/{projectId}/changes/{changeId}/reject",
            post(agent_api::reject_change),
        )
        .route(
            "/api/v1/projects/{projectId}/changes/{changeId}/request-changes",
            post(agent_api::request_changes),
        )
}
