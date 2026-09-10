import Foundation

extension SparkErrorCopy {
    static func model(_ code: String) -> String? {
        switch code {
        case "MODEL_RECIPE_INVALID", "MODEL_RECIPE_REVISION_MISMATCH":
            String(localized: "The signed recipe changed. Request a new review and read it again.")
        case "MODEL_RECIPE_UNTRUSTED":
            String(
                localized:
                    "This recipe is not signed by a source this Spark trusts, so it will not run."
            )
        case "MODEL_LICENCE_REQUIRED":
            String(localized: "This model needs its licence accepted with the provider first.")
        case "CREDENTIAL_INVALID", "CREDENTIAL_NOT_FOUND", "CREDENTIAL_PROVIDER_MISMATCH":
            String(
                localized:
                    "The saved provider credential does not fit this model. Choose or replace it, then retry."
            )
        case "MODEL_DOWNLOAD_AUTH_REQUIRED":
            String(localized: "The provider needs a credential for this model before downloading.")
        case "MODEL_DOWNLOAD_FAILED":
            String(localized: "The download stopped. Finished parts are kept; retry to resume.")
        case "MODEL_DIGEST_MISMATCH":
            String(
                localized:
                    "The downloaded files did not match the signed recipe and were discarded. Retry the download."
            )
        case "MODEL_INSUFFICIENT_DISK":
            String(
                localized: "There is not enough free disk for this model. Free space, then retry."
            )
        case "MODEL_NOT_INSTALLED":
            String(localized: "That model is not installed on this Spark. Install it first.")
        case "MODEL_ALREADY_INSTALLED":
            String(localized: "That revision is already installed. Use it, or remove it first.")
        case "MODEL_MANIFEST_UNAVAILABLE":
            String(
                localized:
                    "The provider's file list could not be read. Check the provider, then request a new review."
            )
        case "MODEL_INSUFFICIENT_MEMORY":
            String(
                localized:
                    "This profile needs more memory than the Spark has free. Choose a smaller context or profile."
            )
        case "MODEL_LOAD_FAILED", "MODEL_HEALTH_CHECK_FAILED":
            String(
                localized: "The model did not start. Try the safe profile, or read its diagnostics."
            )
        case "MODEL_DRAIN_TIMEOUT":
            String(
                localized:
                    "Requests are still finishing on this model. Wait, or stop it without waiting."
            )
        case "MODEL_UNLOAD_FAILED":
            String(
                localized:
                    "The Spark could not stop this model. Check its health before starting anything else."
            )
        case "MODEL_ACTIVE":
            String(localized: "That model is running. Stop it before removing it.")
        case "MODEL_LOAD_IN_PROGRESS":
            String(
                localized: "That model is still starting. Wait for it to settle, then try again."
            )
        case "MODEL_REMOVE_REFERENCED":
            String(
                localized:
                    "Other records still reference this model, so the Spark kept it. Retire those first."
            )
        case "MODEL_NOT_LOADED":
            String(localized: "No model is loaded on this Spark yet.")
        case "MODEL_RESPONSE_EMPTY":
            String(localized: "The model returned nothing. Try again, or choose another model.")
        case "MODEL_PROFILE_UNSAFE":
            String(
                localized:
                    "This profile was disabled after a memory failure. Review its measurements and re-enable it first."
            )
        case "MODEL_PROFILE_ALREADY_SAFE":
            String(localized: "That profile is already enabled. Refresh the model's details.")
        case "MODEL_PROFILE_REENABLE_FAILED":
            String(localized: "The profile stayed disabled. Try the review again.")
        case "PROFILE_NOT_FOUND":
            String(localized: "That profile does not belong to this model's signed recipe.")
        case "MEMORY_PRESSURE_ACTIVE":
            String(
                localized:
                    "The Spark is under memory pressure. Wait for it to settle before loading a model."
            )
        case "ENGINE_ACTIVE":
            String(localized: "Another model is running. Stop it, or choose to replace it.")
        case "ENGINE_NOT_READY", "ENGINE_DRAINING":
            String(localized: "The Spark's engine is still changing state. Wait, then retry.")
        default: nil
        }
    }

    static func operations(_ code: String) -> String? {
        cluster(code) ?? project(code) ?? update(code)
    }

    private static func cluster(_ code: String) -> String? {
        switch code {
        case "MEMBERSHIP_DUPLICATE":
            String(localized: "Each Spark can only be selected once.")
        case "CLUSTER_MANAGEMENT_UNAVAILABLE":
            String(
                localized:
                    "This build cannot manage a cluster. Keep these Sparks standalone for now."
            )
        case "CLUSTER_INFERENCE_UNAVAILABLE":
            String(
                localized:
                    "Distributed inference is not qualified on this build. Use a single Spark."
            )
        case "CLUSTER_NODE_UNREACHABLE":
            String(localized: "A member of this cluster did not answer. Check its power and link.")
        case "CLUSTER_VERSION_MISMATCH":
            String(localized: "The cluster's Sparks run different versions. Update them to match.")
        case "CLUSTER_LINK_UNHEALTHY":
            String(
                localized:
                    "The link between these Sparks is unhealthy. Check the cable, then validate again."
            )
        case "CLUSTER_COLLECTIVE_TEST_FAILED":
            String(
                localized: "The cluster's connection test failed. Its diagnostics hold the reason."
            )
        case "CLUSTER_WORKER_LOST":
            String(localized: "A cluster member dropped out. The distributed job stopped safely.")
        case "CLUSTER_CREATE_FAILED":
            String(localized: "The cluster was not formed. Both Sparks remain standalone.")
        case "CLUSTER_VALIDATE_FAILED":
            String(
                localized: "Cluster validation failed. Repair what it names, then validate again."
            )
        default: nil
        }
    }

    private static func project(_ code: String) -> String? {
        switch code {
        case "PROJECT_NOT_FOUND", "CHANGE_NOT_FOUND":
            String(localized: "That item is no longer on this Spark. Refresh the list.")
        case "PROJECT_SANDBOX_START_FAILED":
            String(localized: "The project's container did not start. Its logs hold the reason.")
        case "PROJECT_PATH_INVALID":
            String(localized: "That path is not inside this project.")
        case "FILE_CONFLICT", "PROJECT_CONFLICT":
            String(localized: "This changed elsewhere while you were editing. Merge both versions.")
        case "AGENT_APPROVAL_REQUIRED":
            String(localized: "This change is waiting for your approval.")
        case "AGENT_POLICY_DENIED":
            String(localized: "This project's policy does not allow that agent action.")
        case "BUILD_WORKER_UNAVAILABLE":
            String(localized: "No Mac build worker is available. Connect one, or queue the build.")
        case "BUILD_COMMIT_NOT_IMMUTABLE":
            String(localized: "A build has to name an exact commit.")
        case "OPERATION_NOT_FOUND":
            String(localized: "That job is no longer on this Spark. Refresh the list.")
        case "OPERATION_NOT_CANCELLABLE":
            String(localized: "This job has passed the point where it can be cancelled.")
        default: nil
        }
    }

    private static func update(_ code: String) -> String? {
        switch code {
        case "UPDATE_SIGNATURE_INVALID", "UPDATE_VERIFICATION_FAILED":
            String(localized: "That update failed its signature check and was not installed.")
        case "UPDATE_INCOMPATIBLE":
            String(localized: "That update does not fit this Spark. It kept its current version.")
        case "UPDATE_HEALTH_CHECK_FAILED", "UPDATE_ROLLED_BACK":
            String(localized: "The update did not pass its health check, so the Spark rolled back.")
        case "UPDATE_STAGING_INVALID", "UPDATE_NO_TRUST_ROOT":
            String(
                localized:
                    "The Spark could not verify the staged update. A one-time assisted install repairs this."
            )
        case "UPDATE_SCHEDULE_FAILED", "UPDATE_SYSTEM_WORKER_LOST", "RUNTIME_UPDATE_FAILED":
            String(localized: "The Spark could not run the update. Nothing was changed.")
        case "UPDATE_NOT_QUIESCENT":
            String(localized: "Stop the running model or project container before updating.")
        case "UPDATE_BLOCKED_BY_OPERATION":
            String(
                localized:
                    "Another operation is still running on this Spark. The update can start once it finishes."
            )
        case "SYSTEM_UPDATE_FAILED":
            String(
                localized: "The system update stopped part way. Its recorded step holds the reason."
            )
        case "SYSTEM_UPDATE_STATUS_TIMEOUT":
            String(localized: "The Spark is still applying its update. Check again shortly.")
        case "PRIVATE_OVERLAY_ROLLBACK_INCOMPLETE":
            String(
                localized:
                    "Remote access was not turned on, and the Spark could not fully undo the Tailscale setup it started. It may still be signed in to your Tailscale network, or the Tailscale service may still be running. Turn remote access off to try the undo again."
            )
        case "REMOTE_ENABLE_FAILED":
            String(localized: "Remote access was not enabled. Local access is unchanged.")
        case "REMOTE_DISABLE_FAILED":
            String(
                localized:
                    "Remote access may still be reachable. Retry while near the Spark and verify it is off."
            )
        case "REMOTE_DISABLE_STATUS_TIMEOUT":
            String(localized: "The Spark did not confirm in time. Check the job again.")
        case "OPERATION_LEASE_EXPIRED":
            String(
                localized:
                    "The Spark stopped reporting on this job, usually because it restarted. Refresh before retrying."
            )
        case "OPERATION_CANCELLED":
            String(localized: "This action was cancelled.")
        default: nil
        }
    }
}
