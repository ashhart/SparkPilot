# SparkPilot recipe release checklist

Use this checklist for each new model and every change to its weights, engine, patches or launch settings. Keep the completed evidence with the release review; do not treat a signature or a successful chat as security approval.

## 1. Identify exactly what will run

- [ ] Record the model publisher, repository, immutable revision, architecture, format, download size and required files.
- [ ] Pin the engine image by digest and platform; never use a moving tag as release identity.
- [ ] Pin every patch and build input by revision and SHA-256, including dependencies and generated modules.
- [ ] Compare the actual built modules with the reviewed source and retain the resulting hashes.
- [ ] Do not fetch or execute the latest upstream Python or shell scripts during setup or model launch.
- [ ] Confirm redistribution obligations for weights, code and images, including notices and source availability.

## 2. Review code and dependencies

- [ ] Review all added Python, shell, native code, build commands and generated changes, including code embedded in strings.
- [ ] Check network clients, subprocesses, dynamic imports, deserialization, environment access, filesystem writes, logs, telemetry and update mechanisms.
- [ ] Inspect the base image and transitive dependencies, produce an SBOM and triage vulnerability scan results.
- [ ] Verify build steps run without user data, credentials, host files, Docker sockets or unnecessary network access.
- [ ] Require an independent security review for executable third-party changes before approving distribution.
- [ ] Treat scanner results and source popularity as evidence, not proof of safety.

## 3. Keep model files as data

- [ ] Require `trustRemoteCode: false` and confirm the actual engine receives no remote-code override.
- [ ] Prefer safetensors and explicitly prevent fallback to pickle-backed weights, arbitrary Python, plugins or repository-provided loaders.
- [ ] Inspect model/tokenizer configuration, custom-code mappings and artifact indexes for unexpected dependencies or paths.
- [ ] Verify all downloaded bytes against the pinned manifest and reject path traversal, symlinks outside the snapshot, incomplete files and checksum mismatches.
- [ ] Publish installed state only after files are durably verified; test disk-full, interruption, corruption and resume.
- [ ] Keep download credentials in the downloader; do not pass Hugging Face or account tokens to the inference container.

## 4. Enforce the container boundary

- [ ] Run inference as the restricted service UID with capabilities dropped, no privilege escalation and a read-only root filesystem.
- [ ] Mount only the required model snapshot and narrowly scoped caches; never mount home directories, project stores, account credentials, runtime databases or Docker sockets.
- [ ] Separate writable executable caches by engine identity and review cache migration to prevent one engine poisoning another.
- [ ] Bound memory, swap, processes, temporary storage and preparation jobs; avoid privileged containers and unnecessary host namespaces.
- [ ] Check GPU access and the host driver/toolkit patch level; a container shares the host kernel and is not a virtual machine.
- [ ] Make any host tuning a fixed, validated operation with durable ownership, rollback and restoration after failure, unload and restart.

## 5. Prove network isolation on a real Spark

- [ ] Default inference to no outbound network access; offline environment variables alone are not an access-control boundary.
- [ ] Block Docker DNS forwarding as well as normal resolver queries, direct UDP/TCP DNS and alternate DNS destinations.
- [ ] Block new outbound IPv4/IPv6 connections and datagrams to the Internet, LAN, host services, link-local addresses and other containers.
- [ ] Check one-way UDP traffic, not merely whether a connection received a reply; disabling NAT is insufficient.
- [ ] Allow only the runtime's intended loopback request path and its replies; test streamed responses, cancellation and reconnection.
- [ ] Verify the installed firewall rules, bridge identity and container DNS configuration before starting inference; fail closed on missing permissions or changed rules.
- [ ] Repeat tests after Docker/runtime/host restarts and test migration of existing containers, not only fresh launches.
- [ ] Test harmless malicious-code fixtures that attempt DNS, HTTP, host-file access and cross-container access without sending real user data.
- [ ] Keep optional web search in its separately authorized service; do not give the model process general Internet access to implement search.

## 6. Qualify memory and performance

- [ ] Measure weights, CPU offload, GPU allocations, context cache, engine overhead and host reserve on the target hardware.
- [ ] Measure free pages and clean file-cache residency as well as `MemAvailable`; CUDA can return success after an internal NVIDIA allocation failure, so compare cold and warm kernel logs and use a small allocation reproducer before changing allocator settings. Any page-cache release must target only owned, verified files and preserve their contents; never drop global caches.
- [ ] Verify compatibility with SparkPilot's actual memory/thermal guards and other supported services; do not silently weaken global protections.
- [ ] Replay measured headroom and PSI through `spark-telemetry`'s `replay_memory_guard` example; staying above the emergency floor alone does not avoid admission draining or graceful unload.
- [ ] Run `python3 tests/hardware/qwen_memory_gate.py EVIDENCE_DIRECTORY` for a Qwen experiment; successful HTTP replies must still fail qualification if admissions stop, NVIDIA allocation errors occur, pressure evidence is missing or host settings are not restored.
- [ ] After stopping a native probe, collect its kernel evidence on that Spark with `sudo python3 tests/hardware/qwen_memory_gate.py --collect-kernel EVIDENCE_DIRECTORY`; the collector uses absolute UTC boundaries, because Docker timestamps and the host's journal timezone can differ.
- [ ] Distinguish maximum context per request from the total concurrent cache capacity; do not advertise several full-length requests without testing them.
- [ ] Test the default preset, the largest supported context, parallel requests, overload/queueing and out-of-memory recovery.
- [ ] Measure cold and warm startup, time to first answer and sustained generation with reproducible prompts and stated thinking settings.
- [ ] Record hardware, engine digest, recipe revision and test conditions alongside performance claims.

## 7. Exercise the app-managed lifecycle

- [ ] Start from a Spark without the engine, model or preparation cache and install through SparkPilot.
- [ ] Verify download, image preparation, offline preprocessing, launch and health-check progress; unknown percentages must remain indeterminate.
- [ ] Test cancellation, app backgrounding, connection loss, restart, retry and cache reuse without duplicate downloads or orphaned processes.
- [ ] Verify launch review, one-tap preset, thinking controls, context limits and the remembered idle/unload policy.
- [ ] Test manual unload, idle unload, never-unload mode, replacement by another model and failed replacement rollback.
- [ ] Confirm host settings and memory recover after successful unload, failed startup and emergency stop.
- [ ] Preserve externally adopted workloads and user recipes; ownership and destructive actions must be explicit.

## 8. Verify advertised capabilities

- [ ] Test ordinary chat, streaming, cancellation, long conversations and reconnecting to the same Spark.
- [ ] Test reasoning on/off and budget behavior without exposing internal reasoning as a final reply.
- [ ] Exercise tool calls through the real engineering harness, including parallel calls if advertised.
- [ ] Test images, video, structured output and audio only where the recipe advertises support; unsupported inputs need clear app feedback.
- [ ] Verify model IDs, parser names, stop tokens and API behavior used by chat, voice and every supported harness.
- [ ] Confirm prompts, replies, images and tool output are not sent to external services or written to diagnostic logs by default.

## 9. Sign, package and publish deliberately

- [ ] Validate the recipe schema, canonical signature and independent privileged-helper allowlist.
- [ ] After changing any entry, reassemble and sign the whole catalogue with `tools/catalogue/spark_catalogue.py assemble`, then run its `verify` command against both the packaged bootstrap and app preset catalogue; a valid recipe signature does not repair a stale snapshot signature.
- [ ] Verify older app/runtime compatibility; use a compatible feed or explicit version requirement rather than breaking existing catalogues.
- [ ] Distinguish a recipe-only update from one that requires new runtime code; test the updater's full version/revision comparison.
- [ ] Build reproducibly, verify signatures and package contents, and run installation/upgrade/rollback checks.
- [ ] Test the exact signed package and app build intended for release on hardware.
- [ ] Publish only recipes that passed the release gates; clearly label standalone experiments and pending app integration on the website.
- [ ] Add the approved unsigned canonical recipe SHA-256 to `packaging/catalogue/release-approvals.json`; publication and TestFlight tooling refuse missing or stale approvals.
- [ ] Ensure a reviewed revocation/rollback path exists for a compromised model, engine or signing key.
- [ ] Respect deployment holds and record the exact versions actually installed or published.

## Release decision

All mandatory checks need evidence or an explicit documented reason they do not apply. Missing isolation, unreviewed executable code, unsafe file loading, unresolved memory failures or untested packaged installation block release. Record the approval against the exact recipe digest in the release review.
