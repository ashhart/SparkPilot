import SwiftUI

struct SparkQualificationView: View {
    @State private var runner: SparkQualificationRunner
    @State private var confirmStart = false
    @State private var confirmClear = false
    @State private var reproduction: SparkQualificationManifest?
    @Environment(\.scenePhase) private var scenePhase

    init(target: SparkInferenceTestTarget) {
        _runner = State(initialValue: SparkQualificationRunner(target: target))
    }

    var body: some View {
        List {
            Section("Local profile check") {
                Text(verbatim: runner.target.chat.modelName).font(.headline)
                LabeledContent("Serving Spark") { Text(verbatim: runner.target.chat.displayName) }
                LabeledContent("Profile") {
                    Text(verbatim: runner.target.profileID ?? String(localized: "Not reported"))
                }
                Text(
                    "Check this already-loaded deployment with fixed synthetic workloads; no model is loaded, stopped or tuned."
                )
                Text(
                    "The Spark must be idle, the profile must support at least 4,096 context tokens and two sequences, and local request history must be enabled for provenance."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            Section("Maximum work to review") {
                LabeledContent("Requests", value: "11")
                LabeledContent("Generated tokens", value: "960")
                LabeledContent("Concurrent client requests", value: "2")
                LabeledContent("Requested context", value: String(localized: "2,048 prompt tokens"))
                LabeledContent("Total deadline", value: String(localized: "4 minutes"))
                LabeledContent(
                    "Stability window",
                    value: String(localized: "30 seconds, three requests")
                )
                Text(
                    "Input uses fixed text with a 64 KB request-body limit; actual input tokens depend on the tokenizer and are recorded only when reported."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            if let error = runner.errorCode {
                Section {
                    Text(verbatim: qualificationFailureText(error)).foregroundStyle(.secondary)
                }
            }
            if let manifest = runner.manifest {
                Section("Current run") {
                    if runner.isRunning {
                        ProgressView(qualificationPhaseTitle(runner.phase))
                    } else {
                        Text(
                            manifest.state == "completed_incomplete_qualification"
                                ? "Checks finished; qualification remains incomplete"
                                : "Run stopped"
                        )
                    }
                    Text(
                        "Independent model-byte, tokenizer, template, driver, library and hardware attestation are still missing; this run cannot promote a profile."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                    ForEach(SparkQualificationCase.allCases, id: \.self) { kind in
                        LabeledContent {
                            Text(
                                verbatim: manifest.cases.first(where: { $0.kind == kind })?.verdict
                                    .title ?? String(localized: "Not run")
                            )
                        } label: {
                            Text(verbatim: kind.title)
                        }
                    }
                    if manifest.isTerminal {
                        NavigationLink("Review measured evidence") {
                            SparkQualificationDetailView(manifest: manifest)
                        }
                    }
                }
            }
            Section {
                if runner.isRunning {
                    Button("Cancel all checks", role: .destructive) { runner.cancel() }
                } else {
                    Button("Review and start checks") {
                        reproduction = nil
                        confirmStart = true
                    }
                }
            } footer: {
                Text(
                    "Changing the deployment, unexpected work, unsafe memory, cancellation or leaving this screen or the app stops the run; engine termination after cancellation remains unconfirmed."
                )
            }
            Section("Saved runs") {
                if runner.saved.isEmpty {
                    Text("No saved qualification runs.").foregroundStyle(.secondary)
                }
                ForEach(runner.saved) { run in
                    NavigationLink {
                        SparkQualificationDetailView(manifest: run) {
                            reproduction = run
                            confirmStart = true
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(verbatim: run.identity?.modelID ?? runner.target.chat.modelID)
                                .font(.headline)
                            Text(run.createdAt, format: .dateTime.month().day().hour().minute())
                            Text(
                                run.state == "completed_incomplete_qualification"
                                    ? "Measured; incomplete qualification" : "Interrupted or failed"
                            )
                            .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Button("Clear finished qualification runs", role: .destructive) {
                    confirmClear = true
                }.disabled(runner.isRunning)
            }
        }
        .navigationTitle("Check this profile")
        .alert(
            reproduction == nil
                ? "Start local profile checks?" : "Reproduce this recorded configuration?",
            isPresented: $confirmStart
        ) {
            Button("Start 11 synthetic requests") { runner.start(reproducing: reproduction) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Up to 960 generated tokens, two concurrent clients and four minutes on the selected Spark; the run stops if the recorded deployment changes, and does not authorize tuning or promotion."
            )
        }
        .alert(
            "Clear finished qualification runs?",
            isPresented: $confirmClear
        ) {
            Button("Clear finished runs", role: .destructive) { runner.clearFinished() }
            Button("Cancel", role: .cancel) {}
        }
        .onChange(of: scenePhase) { _, value in
            if value != .active { runner.cancel(suspended: true) }
        }
        .onDisappear { runner.cancel(suspended: true) }
    }
}

private struct SparkQualificationDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let manifest: SparkQualificationManifest
    var reproduce: (() -> Void)? = nil
    var body: some View {
        List {
            Section {
                Text("Measured evidence does not by itself complete qualification.").font(.headline)
                Text(
                    "Correctness is one arithmetic case and one exact echo; a token-limited or missing answer is not demonstrated, while a completed wrong answer fails; latency includes client readiness checks, context uses reported prompt tokens, concurrency requires the engine sample time to fall within both owned request windows, and stability covers only the stated short window."
                )
                Text("Warmth: already loaded; caches and cold start are not controlled.").font(
                    .caption
                ).foregroundStyle(.secondary)
            }
            ForEach(manifest.cases) { result in
                Section {
                    LabeledContent("Result") { Text(verbatim: result.verdict.title) }
                    LabeledContent("Samples") { Text(verbatim: result.sampleCount.formatted()) }
                    if let value = result.value {
                        LabeledContent(primaryLabel(result.kind)) {
                            Text(
                                verbatim: value.formatted(.number.precision(.fractionLength(0...3)))
                            )
                        }
                    }
                    if let value = result.secondaryValue {
                        LabeledContent(secondaryLabel(result.kind)) {
                            Text(
                                verbatim: value.formatted(.number.precision(.fractionLength(0...3)))
                            )
                        }
                    }
                } header: {
                    Text(verbatim: result.kind.title)
                }
            }
            if let identity = manifest.identity {
                Section("Recorded configuration") {
                    LabeledContent("Model") { Text(verbatim: identity.modelID) }
                    LabeledContent("Profile") { Text(verbatim: identity.profileID) }
                    LabeledContent("Recipe revision") { Text(verbatim: identity.recipeRevision) }
                    LabeledContent("Runtime") { Text(verbatim: identity.runtimeVersion) }
                    Text(
                        "Reproduction requires the same reported recipe, model source, engine image, settings and runtime; absent independent attestation still prevents full qualification."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                if let reproduce {
                    Button("Reproduce recorded configuration") {
                        dismiss()
                        reproduce()
                    }
                    .disabled(manifest.identity?.deployment == nil || !manifest.isTerminal)
                }
                NavigationLink("Review evidence to share") {
                    SparkQualificationExportView(manifest: manifest)
                }
                DisclosureGroup(String(localized: "Integrity digest")) {
                    Text(verbatim: manifest.evidenceDigest).font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            } footer: {
                Text(
                    "The local digest detects changed evidence; it is not a signed qualification or catalogue authorization."
                )
            }
        }
        .navigationTitle("Qualification evidence")
    }
    private func primaryLabel(_ kind: SparkQualificationCase) -> String {
        switch kind {
        case .latency: String(localized: "p50 client seconds")
        case .context: String(localized: "Reported prompt tokens")
        case .concurrency: String(localized: "Peak sampled engine requests")
        case .memory: String(localized: "Minimum sampled available bytes")
        case .stability: String(localized: "Observed span in seconds")
        default: String(localized: "Measured value")
        }
    }
    private func secondaryLabel(_ kind: SparkQualificationCase) -> String {
        switch kind {
        case .latency: String(localized: "p95 client seconds")
        case .context: String(localized: "Requested prompt tokens")
        case .concurrency: String(localized: "Client overlap in seconds")
        case .memory: String(localized: "Minimum sampled headroom bytes")
        default: String(localized: "Additional measured value")
        }
    }
}

private struct SparkQualificationExportView: View {
    let manifest: SparkQualificationManifest
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Review before sharing").font(.title2.bold())
                Text(
                    "This contains synthetic workload IDs, model/profile metadata, measurements and missing evidence; it excludes responses, thoughts, credentials, addresses, names, caller/node/request IDs and exact wall-clock times."
                )
                if let json = try? SparkQualificationExport(manifest).encoded() {
                    Text(verbatim: json).font(.caption.monospaced()).textSelection(.enabled)
                    ShareLink(item: json) {
                        Label(
                            "Share reviewed qualification evidence",
                            systemImage: "square.and.arrow.up"
                        )
                    }
                }
            }.padding(24)
        }.navigationTitle("Share measured evidence")
    }
}

private func qualificationPhaseTitle(_ phase: String) -> String {
    SparkQualificationCase(rawValue: phase)?.title
        ?? String(localized: "Checking the current deployment")
}

func qualificationFailureText(_ code: String) -> String {
    switch code {
    case "PROVENANCE_UNAVAILABLE":
        String(
            localized:
                "The runtime did not provide exact attempt evidence; enable local request history and update the runtime before retrying."
        )
    case "IDENTITY_CHANGED", "DEPLOYMENT_CHANGED":
        String(
            localized: "The Spark identity or recorded deployment changed; all checks were stopped."
        )
    case "OTHER_WORK_OBSERVED":
        String(
            localized:
                "Other inference work was observed; wait until the Spark is idle before retrying."
        )
    case "MEMORY_GUARD_OR_RESERVE":
        String(localized: "The memory guard or required reserve stopped the checks.")
    case "PROFILE_TOO_SMALL":
        String(
            localized:
                "This preset needs an already-loaded safe profile with at least 4,096 context tokens and two sequences."
        )
    case "OWNER_CANCELLED_ENGINE_STOP_UNCONFIRMED", "APP_SUSPENDED_OUTCOME_UNKNOWN", "CANCELLED":
        String(localized: "Checks stopped; engine termination is unconfirmed.")
    case "RUN_TIMEOUT", "REQUEST_TIMEOUT":
        String(localized: "The stated time limit was reached and the checks stopped.")
    case "EVIDENCE_STORAGE_UNREADABLE", "EVIDENCE_STORAGE_FAILED", "EVIDENCE_CLEAR_FAILED":
        String(
            localized:
                "Measurement evidence could not be saved or read; existing files were preserved."
        )
    case "REPRODUCTION_PROVENANCE_MISSING":
        String(localized: "This run lacks the deployment evidence required for exact reproduction.")
    default:
        String(
            localized:
                "A check did not complete correctly; review the recorded case outcomes before trying again."
        )
    }
}
