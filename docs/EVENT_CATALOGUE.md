# Spark Runtime event catalogue

Envelope schema: `contracts/schemas/runtime-event.schema.json`.

An entry marked **planned** has no producer in this runtime: a client may not
subscribe to it and expect anything. `tests/contract/test_event_catalogue.py`
holds the same list and fails in both directions, so a type cannot be
published without being documented, and cannot be documented as live without
being published.

## Node and runtime

- `node.status.changed` — planned: no producer in this runtime yet
- `node.route.changed` — planned: no producer in this runtime yet
- `node.memory.pressure.changed`
- `node.temperature.warning`
- `node.runtime.update.available` — planned: no producer in this runtime yet
- `node.runtime.update.progress` — planned: no producer in this runtime yet
- `node.runtime.update.completed` — planned: no producer in this runtime yet
- `node.runtime.update.failed` — planned: no producer in this runtime yet

## Identity and security

- `device.paired`
- `device.revoked`
- `pairing.invitation.created` — planned: written as an audit record today, never published as an event
- `pairing.invitation.claimed` — planned: written as an audit record today, never published as an event
- `pairing.invitation.expired` — planned: no producer in this runtime yet
- `security.signature.rejected`
- `security.replay.rejected`
- `security.join_code.locked`
- `shared_access.invitation.created` — planned: written as an audit record today, never published as an event
- `shared_access.updated`
- `shared_access.revoked`
- `guest.request.admitted` — planned: written as an audit record today, never published as an event
- `guest.request.refused`
- `guest.route.refused` — planned: written as an audit record today, never published as an event
- `security.tls.identity.mismatch` — planned: no producer in this runtime yet

## Models and inference

- `model.download.queued` — planned: no producer in this runtime yet
- `model.download.progress`
- `model.download.verifying` — planned: no producer in this runtime yet
- `model.download.completed` — planned: no producer in this runtime yet
- `model.download.failed` — planned: no producer in this runtime yet
- `model.load.preflight` — planned: no producer in this runtime yet
- `model.load.progress` — planned: no producer in this runtime yet
- `model.ready`
- `model.draining`
- `model.unloaded`
- `model.failed`
- `model.memory.guard.armed`
- `model.memory.guard.triggered`
- `inference.request.started` — planned: no producer in this runtime yet
- `inference.request.first_token` — planned: no producer in this runtime yet
- `inference.request.completed` — planned: no producer in this runtime yet
- `inference.request.cancelled` — planned: no producer in this runtime yet
- `inference.request.failed` — planned: no producer in this runtime yet
- `inference.usage.recorded` — planned: no producer in this runtime yet
- `model.load_failed` — the plan calls this `model.failed`; both names are published
- `model.unload_failed`
- `model.idle.unloaded`
- `model.idle.unload_failed`
- `model.guard.stopped`
- `model.guard.stop_failed`
- `engine.draining` — the plan calls this `model.draining`; both names are published
- `workload.adopted`
- `workload.adoption_failed`

## Durable operations

Every operation kind publishes this family from the durable job service, so a
client that reattaches by `operation_id` sees the same transitions the
`operations` row records. The payload carries `kind`, `state`, `stage`,
`progress`, `error_code` and `resource_id` — never operation input or results.

- `operation.created`
- `operation.progress`
- `operation.awaiting_approval` — planned: no producer in this runtime yet; not emitted; approvals are their own resource, not an operation state
- `operation.cancelled`
- `operation.completed`
- `operation.failed`
- `operation.lease.lost` — a worker finished after its lease had been taken from it; the result was discarded and the operation stayed with whoever holds the lease now. The payload carries `held_fence`, `requested_state` and `error_code`.

## Fabric

Published by a bounded sysfs sampler, so a cable inserted before boot or during
use is announced without an app restart or a replug. `fabric.validation_progress`
is published as `cluster.validation.progress` because the checks belong to the
cluster transaction that runs them.

- `fabric.carrier_detected`
- `fabric.speed_changed`
- `fabric.ready`
- `fabric.degraded`
- `fabric.peer_authenticated`

## Cluster

- `cluster.node.joined`
- `cluster.node.left`
- `cluster.link.changed`
- `cluster.validation.progress`
- `cluster.ready`
- `cluster.degraded`
- `cluster.model.started` — planned: no producer in this runtime yet
- `cluster.model.failed` — planned: no producer in this runtime yet

## Projects, agents, and builds

- `project.created`
- `project.container.started` — planned: no producer in this runtime yet
- `project.container.stopped` — planned: no producer in this runtime yet
- `project.file.changed` — planned: no producer in this runtime yet
- `project.preview.ready` — planned: no producer in this runtime yet
- `project.preview.failed` — planned: no producer in this runtime yet
- `agent.started` — planned: no producer in this runtime yet
- `agent.plan.ready` — planned: no producer in this runtime yet
- `agent.tool.requested` — planned: no producer in this runtime yet
- `agent.approval.required` — planned: no producer in this runtime yet
- `agent.change.ready` — planned: no producer in this runtime yet
- `agent.test.completed` — planned: no producer in this runtime yet
- `agent.merged` — planned: no producer in this runtime yet
- `agent.failed` — planned: no producer in this runtime yet
- `build.worker.online`
- `build.worker.offline`
- `build.started`
- `build.log.chunk` — planned: no producer in this runtime yet
- `build.test.completed`
- `build.artifact.ready`
- `build.failed`
- `project.deleted`
- `project.terminal.opened`
- `project.terminal.closed`
- `agent.tool` — the plan calls this `agent.tool.requested`
- `change.review_ready` — the plan calls this `agent.change.ready`
- `change.merged` — the plan calls this `agent.merged`
- `change.rejected` — a reviewer closed the change; its worktree, diff, tests and tool audit stay for the record
- `change.changes_requested` — a reviewer asked for corrections; the change goes back to `editing` with its worktree, diff, tests and tool audit intact, and a later review must produce a new digest
- `change.failed` — the plan calls this `agent.failed`
- `build.completed`
- `build.cancelled`

## Automations and web tools

- `automation.run.started`
- `automation.run.completed`
- `automation.run.failed`
- `automation.run.panicked` — the model loop behind a run fell over; the run is failed with `AUTOMATION_RUN_PANICKED` and the scheduler carries on
- `automation.slots.missed` — the Spark was not running, or its clock jumped forward, so slots went by. One event covers the whole backlog and carries `missed`, `counted_to_limit`, `first_missed_slot` and `resumes_at`; the schedule resumes at the first slot after now rather than catching up.
- `web.search.performed` — planned: written as an audit record today, never published as an event
- `web.search.refused` — planned: written as an audit record today, never published as an event
- `web.fetch.performed` — planned: written as an audit record today, never published as an event
- `web.fetch.refused` — planned: written as an audit record today, never published as an event
- `web.robots.checked` — planned: written as an audit record today, never published as an event
- `web.personal_context.stripped` — planned: written as an audit record today, never published as an event

Every `web.*` name is written as an audit record today, carrying the exact query
that left the Spark or the final URL that was read, its byte count and its
refusal code; none of them is published as an event yet. The record is appended
as each call ends, not when the run does, so a run that is killed still leaves
the trail of what already went out. `web.robots.checked` is the `robots.txt`
request a fetch makes before reading a host it has not read in this run;
`web.personal_context.stripped` says the owner's calendar block was taken out of
the transcript before the model could compose a query from it.
An automation run carries no result text in its event; the result is read from
the run's own history, which the owner's devices fetch when they open it.

## Remote access

- `remote.preferences.changed`: emitted after a verified Spark VPN or Tailscale DNS preference change; the payload contains the resulting `enabled` and `accept_dns` booleans, without credentials or login links.
- `remote.tunnel.enabled`
- `remote.tunnel.disabled`
- `remote.tunnel.unhealthy`
- `remote.route.hostname_changed` — the published hostname the Spark answers on moved; the payload carries the previous and current values so the owner can see which address their traffic now takes
- `remote.overlay.login_required` — a one-tap enable is waiting for the owner's Tailscale sign-in; the link itself is never in the payload
- `remote.overlay.rolled_back` — an enable failed and everything it had started was undone: the Spark is signed out again and the Tailscale service it started is stopped
- `remote.overlay.rollback_failed` — an enable failed and could not be fully undone; `remaining` says in plain words what is still in place, and the operation carries `PRIVATE_OVERLAY_ROLLBACK_INCOMPLETE`

## What "planned" means

An entry marked *planned* is a type PLAN §60.2 reserves that nothing in this
build publishes. It is kept so the name stays claimed and so a client is never
surprised by it later, but a client must not wait on one: there is no code path
that produces it today, and some are written only as audit records, which their
notes say. `tests/contract/test_event_catalogue.py` holds the same list and
keeps this document honest in both directions, failing when the runtime
publishes a type this catalogue does not list and when the catalogue presents a
type nothing produces as though it were live.

Where a published name differs from the §60.2 name, the published name is
authoritative: event type names are permanent after release, and these shipped.

## Compatibility rules

- Event type names are permanent after release.
- Additive payload fields are allowed.
- Removing/renaming payload fields requires a new type suffix, for example `model.ready.v2`.
- Unknown types are ignored by clients, but sequence positions are retained.
- Canonical state must be refreshed after an event-gap reset.

## Stream visibility and replay

- `GET /api/v1/events` is authenticated and resumes durable events strictly
  after the monotonic sequence in `Last-Event-ID`.
- The current runtime has one implemented visibility class: rows whose
  `visibility_json` is an empty object are public to every paired device.
  Rows with any non-empty visibility rule are retained but are not streamed;
  they remain closed until device/project/role ACL evaluation is implemented.
- A cursor older than retained history returns `409 EVENT_CURSOR_EXPIRED`.
  Malformed, negative, out-of-range, and future cursors are rejected as
  `400 INVALID_REQUEST`.
- Live fan-out lag closes the stream. Clients reconnect with their last
  durable event id; the server never hides an event gap and continues.
- Only successfully persisted envelopes with sequence `>= 1` enter SSE.
  Persistence failures and producers without a database are logged and their
  contract-invalid sequence-zero fan-out is skipped without closing a healthy
  stream.
- Retained history is read through a fixed high-watermark snapshot in batches
  of 16; a stream never materialises its full replay window. Event envelopes
  are limited to 1 MiB, matching the default Apple SSE parser limit. An
  oversized historical row terminates replay and requires operator repair;
  it is never silently skipped.
- Heartbeat comments are sent every 15 seconds while the stream is open.

## Retention classes

Pruning applies the §60.3 floors per class rather than one global row cap, so a
burst of lifecycle events cannot evict security history:

| Class | Types | Default floor | Setting |
|---|---|---|---|
| Security and identity | `security.*`, `device.*`, `pairing.*` | 90 days | `[telemetry] retain_audit_days` |
| Durable operations | `operation.*` | 30 days | `[telemetry] retain_operation_events_days` |
| Lifecycle | everything else | 7 days | `[telemetry] retain_raw_inference_events_days` |

Above every class floor sits the replay floor: the newest
`[operations] event_replay_minimum_count` rows and everything within
`[operations] event_replay_minimum_hours` are always retained, so a client
resuming with `Last-Event-ID` inside that window never receives
`EVENT_CURSOR_EXPIRED`. The tamper-evident audit chain in `audit_records` is
separate and is never pruned.
