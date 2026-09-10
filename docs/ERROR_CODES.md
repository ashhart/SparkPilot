# Spark Runtime error-code contract

Every code is stable once released. Add new codes; do not repurpose old codes.

A row marked **Reserved** has no producer anywhere in this repository: the
runtime never sends it, so a client must not wait for it or build a state
around it. `tests/contract/test_error_codes.py` holds the same list and fails
in both directions, so a documented code cannot quietly stop being sent, and a
reserved code cannot quietly start being sent without the row being corrected.

| Code | HTTP | Retry | Audit | Client action |
|---|---:|---|---|---|
| PREVIEW_BODY_TOO_LARGE | 413 | After reducing asset size | No | Serve preview assets of at most 64 MiB. |
| NODE_NOT_REACHABLE | 503 | Other route | Notice | Try route failover, show cached state. **Reserved: no producer; a Spark that cannot be reached is a transport failure the client sees itself.** |
| TLS_IDENTITY_MISMATCH | 403 | No | Critical | Block and require recovery review. **Reserved: no producer, and the runtime cannot be one. A pinned certificate is checked by the client, so the app raises its own identityMismatch state; this code exists for a future relay that can see the mismatch on the wire.** |
| API_VERSION_UNSUPPORTED | 426 | After update | Warning | Update app/runtime. **Reserved: no producer.** |
| DEVICE_NOT_PAIRED | 401 | After pairing | Notice | Start explicit pairing |
| DEVICE_REVOKED | 401 | No | Warning | Delete local grant and show recovery |
| SIGNATURE_INVALID | 401 | No automatic loop | Warning | Diagnose/re-pair |
| PROTOCOL_UNSUPPORTED | 401 | After update | Notice | Update the app or the runtime so both use the same signing protocol |
| REQUEST_REPLAYED | 409 | New nonce only | Warning | Retry once with a new nonce |
| CLOCK_SKEW_TOO_LARGE | 401 | After clock fix | Notice | Correct system time |
| ROLE_FORBIDDEN | 403 | No | Notice | Disable action |
| AUDIT_UNAVAILABLE | 503 | After service recovery | Critical | Do not retry an elevated mutation until the audit chain is writable |
| USER_PRESENCE_REQUIRED | 403 | After presence | Notice | Invoke LocalAuthentication |
| USER_PRESENCE_NOT_REGISTERED | 403 | After re-pairing or key enrolment | Warning | Explain that this device has no registered presence key |
| USER_PRESENCE_EXPIRED | 403 | After presence | Notice | Request a new LocalAuthentication proof |
| USER_PRESENCE_INVALID | 403 | No automatic loop | Warning | Reject the proof and require a fresh signed request |
| USER_PRESENCE_KEY_CONFLICT | 409 | After recovery | Warning | Keep the registered key; start explicit key recovery to replace it |
| INVITATION_EXPIRED | 410 | New invite | Notice | Ask owner to generate another QR |
| GUEST_AWAITING_OWNER | 403 | After the owner confirms | Notice | Tell the guest the owner has not confirmed their access yet |
| GUEST_ACCESS_PAUSED | 403 | After the owner resumes | Notice | Tell the guest the owner has paused their access |
| GUEST_ACCESS_REVOKED | 403 | No | Warning | Delete the local grant and stop offering the Spark |
| GUEST_ACCESS_EXPIRED | 403 | After a new invitation | Notice | Tell the guest their access has run out |
| GUEST_MODEL_NOT_ALLOWED | 403 | Another model | Notice | Offer only the models the owner shared |
| GUEST_OUTSIDE_HOURS | 403 | Inside the allowed hours | Notice | Show the hours the owner set, in the owner's time zone |
| GUEST_BUDGET_EXHAUSTED | 429 | After the local day rolls over | Notice | Show the budget and when it resets |
| GUEST_CONCURRENCY_LIMIT | 429 | After the guest's other request finishes | Debug | Wait for the guest's own request to finish |
| GUEST_SCHEDULE_UNAVAILABLE | 409 | After the owner fixes the time zone | Warning | The Spark cannot resolve the guest's time zone, so the schedule fails closed |
| GUEST_PARAMETER_NOT_ALLOWED | 422 | Without the parameter | Warning | Shared access covers chat only; tools and stored-conversation parameters are refused |
| SHARED_ACCESS_POLICY_INVALID | 422 | Correct the limits | Notice | Name the limit the owner must fix |
| INVITATION_ALREADY_USED | 409 | No | Warning | Reject reuse |
| IDEMPOTENCY_KEY_REUSED | 409 | New key after inspection | Warning | Treat as client defect |
| PREVIEW_REQUIRED | 428 | After preview | Notice | Request and present a fresh server preview |
| PREVIEW_INVALID | 422 | Correct request | Warning | Reject malformed preview digest |
| PREVIEW_NOT_FOUND | 412 | New preview | Notice | Request a new preview; server evidence is unavailable |
| PREVIEW_EXPIRED | 412 | New preview | Notice | Request a new preview |
| PREVIEW_ACTION_MISMATCH | 409 | Correct action | Warning | Do not reuse a preview for another action or target |
| PREVIEW_ALREADY_ACCEPTED | 409 | New preview | Notice | Do not reuse accepted evidence for another apply request |
| PREVIEW_STALE | 409 | New preview | Notice | Recalculate and present changed evidence |
| EVENT_CURSOR_EXPIRED | 409 | Yes | Debug | Refresh resources and reconnect |
| MODEL_RECIPE_INVALID | 422 | After recipe fix | Error | Block recipe |
| MODEL_RECIPE_UNTRUSTED | 403 | Reviewed import | Warning | Require trusted signature/import |
| MODEL_RECIPE_REVISION_MISMATCH | 409 | New preview | Notice | Review the current signed recipe revision |
| MODEL_LICENCE_REQUIRED | 409 | After action | Notice | Present licence/provider flow. **Reserved: no producer.** |
| CREDENTIAL_INVALID | 422 | Correct request | Warning | Supply a credential UUID |
| CREDENTIAL_NOT_FOUND | 409 | Choose credential | Notice | Select an available provider credential |
| CREDENTIAL_PROVIDER_MISMATCH | 409 | Choose credential | Warning | Select a credential for the recipe provider |
| MODEL_DOWNLOAD_AUTH_REQUIRED | 401 | After credential | Notice | Request scoped provider credential |
| MODEL_DOWNLOAD_FAILED | 500/502 | Yes/resume | Warning | Preserve chunks and retry |
| MODEL_DIGEST_MISMATCH | 422 | Redownload | Critical | Delete corrupt final object and audit |
| MODEL_INSUFFICIENT_DISK | 409 | After cleanup | Notice | Offer cleanup |
| MODEL_NOT_INSTALLED | 404/409 | After install | Debug | Offer installation |
| MODEL_ALREADY_INSTALLED | 409 | After removal | Notice | Use or explicitly remove the installed revision |
| MODEL_MANIFEST_UNAVAILABLE | 409 | After provider recovery | Warning | Restore manifest access and request a new preview |
| MODEL_INSUFFICIENT_MEMORY | 409 | Different profile | Notice | Offer smaller context/cluster |
| MODEL_LOAD_FAILED | 500 | Safe profile once | Error | Stop container, suggest safe profile |
| MODEL_HEALTH_CHECK_FAILED | 500 | Safe profile once | Error | Stop container, retain diagnostics |
| GPU_DRIVER_MISMATCH | operation | After the Spark restarts | Warning | The NVIDIA driver on the Spark was updated but the running kernel still has the old driver loaded; restart the Spark, then launch again. The operation event keeps the helper's version evidence and docker's text |
| MODEL_DRAIN_TIMEOUT | 409 | Admin decision | Warning | Offer force stop. **Reserved: no producer.** |
| MODEL_UNLOAD_FAILED | 500 | Emergency path | Critical | Emergency stop/reboot policy. **Reserved: no producer.** |
| ENGINE_ACTIVE | 409 | After explicit replace | Notice | Offer replace_active=true |
| ENGINE_NOT_READY | 503 | After load | Notice | Show active engine state |
| ENGINE_DRAINING | 503 | After drain | Notice | Retry after drain completes |
| MODEL_NOT_LOADED | 404 | After load | Debug | Offer model load |
| MODEL_ACTIVE | 409 | After proven stop | Notice | Finish a separate stop operation before removal |
| MODEL_LOAD_IN_PROGRESS | 409 | After load settles | Notice | Wait for the durable load to finish before removal |
| MODEL_REMOVE_REFERENCED | 409 | After safe retirement | Warning | Retain model metadata while runtime records reference it |
| ACTIVE_INFERENCE_EVIDENCE_UNAVAILABLE | 409 | After engine recovery | Warning | Restore engine evidence and request a new preview |
| TARGET_IDENTITY_MISMATCH | 409 | Correct target | Warning | Use the node and cluster identity authored by sparkd |
| ANALYSIS_INPUT_INVALID | 422 | Correct request | Notice | Fix the instruction, document, or output bound named in the message |
| MODEL_RESPONSE_EMPTY | operation | Retry once | Warning | The model returned no text; retry or choose another model |
| MEMORY_PRESSURE_ACTIVE | 409 | After pressure clears | Notice | Wait for Normal before loading |
| MODEL_PROFILE_UNSAFE | 409 | After explicit user action | Warning | Review profile measurements and re-enable |
| PROFILE_NOT_FOUND | 400 | Correct request | Warning | Name a profile belonging to the selected signed recipe |
| MODEL_PROFILE_ALREADY_SAFE | Preview blocker | No | Notice | Nothing to re-enable; refresh the model details |
| MODEL_PROFILE_REENABLE_FAILED | Operation failure | Retry | Warning | The profile stayed disabled; retry the review |
| OPERATION_NOT_FOUND | 404 | No | Debug | Refresh operation list |
| OPERATION_NOT_CANCELLABLE | 409 | No | Notice | Explain current stage |
| MEMBERSHIP_DUPLICATE | 422 | Correct request | Warning | Select each Spark only once |
| CLUSTER_MANAGEMENT_UNAVAILABLE | 503 | Not on this build | Warning | Keep Sparks standalone; this build has no production cluster coordinator |
| CLUSTER_INFERENCE_UNAVAILABLE | 409 | Not on this build | Warning | Use a standalone Spark; distributed launch is not qualified |
| CLUSTER_NODE_UNREACHABLE | 503 | Yes | Warning | Restore node/link. **Reserved: no producer.** |
| CLUSTER_VERSION_MISMATCH | 409 | After update | Error | Align runtime/engine versions. **Reserved: no producer.** |
| CLUSTER_LINK_UNHEALTHY | 409 | After repair | Error | Run link validation. **Reserved: no producer.** |
| CLUSTER_COLLECTIVE_TEST_FAILED | 409 | After repair | Error | Inspect NCCL/Ray diagnostics. **Reserved: no producer.** |
| CLUSTER_WORKER_LOST | 503 | After recovery | Critical | Fail distributed job safely. **Reserved: no producer.** |
| CLUSTER_CREATE_FAILED | operation | After inspection | Error | Keep both Sparks standalone and inspect the operation evidence |
| CLUSTER_VALIDATE_FAILED | operation | After repair | Error | Repair the reported link or compatibility issue before new validation |
| PROJECT_NOT_FOUND | 404 | No | Debug | Refresh project list |
| PROJECT_SANDBOX_START_FAILED | 500 | Maybe | Error | Show logs and safe recovery |
| PROJECT_PATH_INVALID | 422 | Correct input | Warning | Reject traversal/invalid path |
| FILE_CONFLICT | 409 | Resolve revision | Notice | Reload/merge three-way |
| PROJECT_CONFLICT | 409 | Resolve revision | Notice | Reload/merge. **Reserved: no producer.** |
| AGENT_APPROVAL_REQUIRED | 409 | After approval | Notice | Present approval UI. **Reserved: no producer; agent execution is not exposed yet.** |
| CHANGE_NOT_FOUND | 404 | No | Debug | Refresh change list |
| AGENT_POLICY_DENIED | 403 | No | Warning | Explain denied capability. **Reserved: no producer; agent execution is not exposed yet.** |
| BUILD_WORKER_UNAVAILABLE | 503 | Yes | Notice | Queue or select another Mac. **Reserved: no producer.** |
| BUILD_COMMIT_NOT_IMMUTABLE | 422 | Correct request | Warning | Require commit hash |
| UPDATE_SIGNATURE_INVALID | 422 | No | Critical | Block update and audit. **Reserved: no producer.** |
| UPDATE_BLOCKED_BY_OPERATION | 409 | After the operation ends | Notice | Name the running operation and offer to wait |
| UPDATE_INCOMPATIBLE | 409 | Different release | Error | Keep current version. **Reserved: no producer.** |
| UPDATE_HEALTH_CHECK_FAILED | 500 | Rollback | Critical | Roll back automatically |
| UPDATE_ROLLED_BACK | 200/notice | No | Warning | Explain retained version. **Reserved: no producer.** |
| UPDATE_STAGING_INVALID | operation | After a runtime fix | Critical | The privileged helper could not read or validate the staged release; offer the one-time SSH install and name the code |
| SYSTEM_UPDATE_FAILED | operation | Retry after reading the recorded step | Critical | The detached OS update worker stopped at a package-manager or firmware step; the operation's details carry the step, its exit status and the tail of its output |
| SYSTEM_UPDATE_STATUS_TIMEOUT | operation | Check the Spark, then retry | Critical | The OS update worker was still running after two hours of polling; the Spark keeps applying, and the next check shows its outcome |
| UPDATE_SYSTEM_WORKER_LOST | operation | Retry | Critical | The OS update worker's unit is gone and it recorded no outcome; nothing was applied by SparkPilot, but the Spark's own journal has the reason |
| UPDATE_SCHEDULE_FAILED | operation | Once | Critical | systemd refused the update worker; name the code, offer the one-time SSH install |
| UPDATE_NOT_QUIESCENT | operation | After stopping workloads | Warning | A model or project container is still running; ask the owner to stop it |
| UPDATE_VERIFICATION_FAILED | operation | No | Critical | The sealed package failed re-verification; block and audit |
| UPDATE_NO_TRUST_ROOT | operation | No | Critical | The installed trust root is missing; the one-time SSH install restores it |
| RUNTIME_UPDATE_FAILED | operation | Once | Critical | The helper gave no `UPDATE_*` reason; show the operation stage |
| REMOTE_ACCESS_UNAVAILABLE | 503 | Yes/local fallback | Notice | Use local/overlay route. **Reserved: no producer.** |
| REMOTE_MODE_INVALID | 422 | Correct request | Warning | Choose a supported remote mode |
| PRIVATE_OVERLAY_UNAVAILABLE | 409 | After enrolling Tailscale | Warning | Enrol Tailscale on the Spark so it has a reachable 100.64/10 address, then request a new review |
| REMOTE_ENABLE_FAILED | operation | After inspection | Error | Keep local access and inspect the operation evidence |
| REMOTE_DISABLE_FAILED | operation | Yes while local | Critical | Retry disable while near the Spark and verify public reachability is removed |
| REMOTE_DISABLE_STATUS_TIMEOUT | client | Check status | Warning | Keep the idempotency key and check the accepted operation again |
| AUTOMATION_NOT_FOUND | 404 | No | Notice | Refresh the list; the automation was deleted |
| AUTOMATION_NAME_INVALID | 400 | Correct input | Notice | Ask for a name of up to eighty characters |
| AUTOMATION_INSTRUCTIONS_INVALID | 400 | Correct input | Notice | Ask for instructions of up to two thousand characters |
| AUTOMATION_SCHEDULE_INVALID | 400 | Correct input | Notice | Show which part of the schedule the Spark could not read |
| AUTOMATION_TIMEZONE_UNKNOWN | 400 | Correct input | Notice | Offer the zones this Spark has; do not fall back to UTC |
| AUTOMATION_TIMEZONE_UNREADABLE | 400 | Correct input | Notice | The zone file exists but this Spark cannot read it as TZif; offer another zone and report the Spark's zone database as damaged |
| AUTOMATION_LIMIT_REACHED | 409 | After deletion | Notice | Ask the owner to delete one first |
| AUTOMATION_RUN_IN_FLIGHT | 409 | After the run | Notice | Show the run already in progress |
| WEB_ACCESS_POLICY_OFF | 403 | After the owner allows it | Notice | Explain that model internet access is off on this Spark |
| WEB_ACCESS_CHATS_NOT_PERMITTED | 403 | After the owner allows it | Notice | Explain that this Spark allows automations only |
| WEB_ACCESS_HARNESS_NOT_PERMITTED | 403 | After the owner allows it | Warning | A third-party client asked for the web tools; the owner has not allowed harnesses |
| WEB_ACCESS_POLICY_INVALID | 400 | Correct input | Notice | Treat as a client defect |
| WEB_SEARCH_BACKEND_INVALID | 400 | Correct input | Notice | Show which part of the search service address was refused |
| WEB_SEARCH_BACKEND_INCOMPLETE | 400 | After configuration | Notice | Ask for the address or key that backend needs |
| WEB_DOMAIN_ENTRY_INVALID | 400 | Correct input | Notice | Ask for a bare domain name, without a scheme or a path |
| WEB_DOMAIN_LIST_TOO_LONG | 400 | Correct input | Notice | Ask the owner to shorten the site list |
| PRIVATE_OVERLAY_SETUP_FAILED | operation | After the named fix | Error | The Spark could not install, start or sign Tailscale in; whatever the enable started has been undone, so show the runtime's reason and offer Turn On again |
| PRIVATE_OVERLAY_LOGIN_TIMEOUT | operation | Yes | Warning | The owner did not finish the Tailscale sign-in within ten minutes; the sign-in has been undone and the Tailscale service stopped, so offer Turn On again for a fresh link |
| PRIVATE_OVERLAY_ROUTE_UNVERIFIED | operation | Yes | Warning | Tailscale signed in but the Spark could not reach itself over its overlay address yet; offer Check Again |
| PRIVATE_OVERLAY_ROLLBACK_INCOMPLETE | operation | After the named fix | Error | The enable failed and the Spark could not be put back as it was; say exactly what is still in place (it may still be signed in to the tailnet, or the Tailscale service may still be running) and offer Turn Off to try the undo again |
| RATE_LIMITED | 429 | Backoff | Notice | Respect Retry-After |
| INTERNAL_ERROR | 500 | Limited | Error | Show request ID, no stack trace |

Preview warning codes are also stable: `MODEL_ROUTE_INTERRUPTION`,
`ACTIVE_REQUESTS_WILL_DRAIN`, `FORCED_STOP_REQUESTED`, and
`MODEL_FILES_RETAINED`. They do not indicate HTTP failure. The preview carries
their owner explanation and recovery action where one exists.

## Error-envelope invariants

- Never include secrets, credentials, prompts, raw completions, or unrestricted file paths.
- Always include a request ID.
- Include an operation ID when the error belongs to a durable operation.
- The server logs the internal cause under the same request/operation ID.
- The client localises known codes; unknown codes use the server-safe message.

## Operation terminal codes

These appear in an operation's `error_code` after it ends, not as an HTTP status.

| Code | Meaning | Client action |
|---|---|---|
| OPERATION_LEASE_EXPIRED | The worker stopped renewing its lease for longer than `operations.lease_seconds` and housekeeping failed the operation; the work behind it may have continued (typically the runtime restarted to apply an update). | Refresh the relevant state before retrying; if a restart is required, restart the Spark. |
| OPERATION_CANCELLED | The owner cancelled the operation before it finished. An automation run cancelled this way records `failed` with this code, because a run's stored states are `running`, `succeeded`, `failed`, `skipped` and `interrupted`; the operation itself reports `cancelled`. | Show the cancellation; nothing to retry automatically. |
| AUTOMATION_RUN_INTERRUPTED | The runtime restarted while this run was in flight and its outcome is unknown. It is never replayed. | Show the interruption; offer Run now. |
| AUTOMATION_SLOT_MISSED | The Spark was not running when this slot came round, and the slot is older than an hour. | Show that the run was missed; the next slot is unchanged. |
| AUTOMATION_RUNNER_UNAVAILABLE | No engine was available to perform the run. | Check that a model is installed and ready. |
| AUTOMATION_RUN_FAILED | The run's durable operation failed without a more specific code. | Show the failure and offer Run now. |
| AUTOMATION_RUN_PANICKED | The model loop behind this run fell over. The run is failed, the scheduler carries on, and the next slot is unaffected. | Show the failure and offer Run now. |
| AUTOMATION_RUN_IN_FLIGHT | This slot did not run because a run of the same automation was still in flight. The run row records it as skipped. | Show that the slot was skipped; the next slot is unchanged. |

## Web tool refusal codes

These appear in a run's tool list and in the tool result the model is shown.
They are never HTTP statuses; the run itself succeeds or fails on its own.

| Code | Meaning | Owner-facing explanation |
|---|---|---|
| WEB_OUTBOUND_BLOCKED | The query or the address carried something private: an email address, a telephone number, a card number, a key or token, or a device or node identifier. | Nothing was sent. |
| WEB_FETCH_SCHEME_BLOCKED | The address was not http or https. | Only web pages are read. |
| WEB_FETCH_URL_INVALID | The address was malformed, carried credentials, or used a port other than 80 or 443. | It was not read. |
| WEB_FETCH_PRIVATE_ADDRESS | The address is this Spark or somewhere inside the owner's own network. | It was not read. |
| WEB_FETCH_HOST_UNRESOLVABLE | The name could not be looked up. | It was not read. |
| WEB_FETCH_ROBOTS_DENIED | The site asks automated readers not to read that page. | It was not read. |
| WEB_FETCH_TOO_MANY_REDIRECTS | The address kept redirecting past three hops. | It was not read. |
| WEB_FETCH_STATUS | The page answered with an error rather than content. | Nothing was read. |
| WEB_FETCH_UNREACHABLE | The page could not be reached. | Nothing was read. |
| WEB_DOMAIN_BLOCKED | The owner's site list does not allow that address. | It was not read. |
| WEB_SEARCH_DISABLED | Search is switched off on this Spark; reading a named page still works. | No search was made. |
| WEB_SEARCH_QUERY_INVALID | The search text was empty or too long. | No search was made. |
| WEB_SEARCH_UNAVAILABLE | The search service refused or could not be reached. | No results. |
| WEB_TOOL_CALL_LIMIT | The run asked for more tool calls than one run is allowed. | The run stopped without an answer. |
| WEB_RUN_BYTE_LIMIT | The run read more than one run is allowed to read. | The run stopped without an answer. |
| WEB_RUN_TIME_LIMIT | The run took longer than one run is allowed to take. | The run stopped without an answer. |
| WEB_HOURLY_LIMIT | This Spark has already made as many web calls as it may in one rolling hour. | Nothing further was sent; a run that had made no call at all makes none. |
| WEB_RUN_MODEL_FAILED | The model on this Spark did not answer. | There is no result. |

## Household notes

| Code | Meaning | Recovery |
|---|---|---|
| HOUSEHOLD_UNAVAILABLE | Household storage could not be read or committed. | Retry after the Spark is available; an unconfirmed save retains its request identity. |
| HOUSEHOLD_ACCESS_REQUIRED | This device is not an active household member. | Ask an owner to grant household membership separately from compute access. |
| HOUSEHOLD_MEMBER_UNAVAILABLE | The selected member cannot be added. | Refresh devices and check its compute access. |
| HOUSEHOLD_OWNER_REQUIRED | This operation needs an owner or administrator. | Use an owner device and confirm presence. |
| HOUSEHOLD_NOTE_INVALID | The note is empty, oversized or invalid. | Correct the note and save again. |
| HOUSEHOLD_NOTE_READ_ONLY | Only its author or an administrator may change this note. | Ask its author or an owner to make the change. |
| HOUSEHOLD_NOTE_CHANGED | Another edit or deletion changed the expected revision. | Refresh and review the latest note before saving the retained draft. |
| HOUSEHOLD_FULL | The household has reached its active-note limit. | Delete an unneeded note before adding another. |
| AUTOMATION_RUN_TIMED_OUT | The task exceeded the execution deadline. | Review its run details and shorten the task before retrying. |
