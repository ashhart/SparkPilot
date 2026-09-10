import SparkAPI
import SwiftUI

struct SparkRequestHistoryView: View {
    @State private var model: SparkRequestHistoryModel
    @State private var confirmClear = false

    init(target: SparkChatTarget) {
        _model = State(initialValue: SparkRequestHistoryModel(target: target))
    }

    var body: some View {
        List {
            Section {
                Text(verbatim: model.target.displayName).font(.headline)
                Text("Requests sent from this device, without prompts or answers.")
                Text(
                    "Up to 2,000 attempts are retained on the Spark for 30 days; filters show the latest 200 matches."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            Section("Filters") {
                TextField("Model ID, or leave empty for all models", text: $model.modelFilter)
                    .onSubmit { Task { await model.refresh() } }
                Picker("Result", selection: $model.outcomeFilter) {
                    Text("All results").tag("")
                    ForEach(SparkRequestHistoryModel.outcomes.filter { !$0.isEmpty }, id: \.self) {
                        outcome in
                        Text(verbatim: sparkRequestOutcomeTitle(outcome)).tag(outcome)
                    }
                }
                Picker("Time", selection: $model.periodHours) {
                    Text("Last 30 days").tag(0)
                    Text("Last hour").tag(1)
                    Text("Last 24 hours").tag(24)
                    Text("Last 7 days").tag(168)
                }
            }
            .disabled(model.busy)
            if let error = model.errorMessage {
                Section { Text(verbatim: error).foregroundStyle(.secondary) }
            }
            if model.recording == false {
                Section {
                    Text("Local telemetry recording is off; request history is not retained.")
                }
            }
            Section("Attempts") {
                if model.records.isEmpty && model.recording != nil && model.errorMessage == nil {
                    Text("No recorded requests match these filters.").foregroundStyle(.secondary)
                }
                ForEach(model.records) { record in
                    NavigationLink {
                        SparkRequestRecordView(
                            record: record,
                            servingNode: model.target.displayName
                        ) {
                            await model.cancel(record)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(verbatim: record.modelID).font(.headline)
                            Text(verbatim: sparkRequestOutcomeTitle(record.outcome))
                            Text(
                                Date(timeIntervalSince1970: TimeInterval(record.startedAt)),
                                format: .dateTime.month().day().hour().minute()
                            )
                            .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section {
                Button("Clear finished request history", role: .destructive) { confirmClear = true }
                    .disabled(model.busy || model.recording == nil)
            } footer: {
                Text("Clearing history preserves running attempts and saved conversations.")
            }
        }
        .navigationTitle("Request history")
        .toolbar {
            Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
                .disabled(model.busy)
        }
        .refreshable { await model.refresh() }
        .task { await model.refresh() }
        .onChange(of: model.outcomeFilter) { _, _ in Task { await model.refresh() } }
        .onChange(of: model.periodHours) { _, _ in Task { await model.refresh() } }
        // An alert, because a popover confirmation drops the cancel button it is given.
        .alert(
            "Clear finished request history?",
            isPresented: $confirmClear
        ) {
            Button("Clear history", role: .destructive) { Task { await model.clearFinished() } }
            Button("Keep history", role: .cancel) {}
        } message: {
            Text("Running attempts and your conversations will be kept.")
        }
    }
}

private struct SparkRequestRecordView: View {
    let record: SparkInferenceRequestRecord
    let servingNode: String
    let cancel: () async -> Bool
    @State private var cancelled = false
    var body: some View {
        List {
            Section("Placement") {
                LabeledContent("Serving Spark") { Text(verbatim: servingNode) }
                LabeledContent("Route", value: String(localized: "Fixed target"))
                LabeledContent("Origin", value: String(localized: "This device"))
                LabeledContent("Model") { Text(verbatim: record.modelID) }
                LabeledContent("Profile") {
                    Text(verbatim: record.profileID ?? String(localized: "Not reported"))
                }
                LabeledContent("Result") {
                    Text(verbatim: sparkRequestOutcomeTitle(record.outcome))
                }
                Text("One admitted attempt; no automatic replay or rerouting.").font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Runtime measurements") {
                timing(String(localized: "Admission check"), record.admissionMs)
                timing(String(localized: "First upstream frame"), record.firstFrameMs)
                timing(String(localized: "Runtime elapsed"), record.elapsedMs)
                LabeledContent("Engine queue time", value: String(localized: "Not reported"))
                LabeledContent("Input tokens") {
                    Text(
                        verbatim: record.promptTokens?.formatted()
                            ?? String(localized: "Not reported")
                    )
                }
                LabeledContent("Output tokens") {
                    Text(
                        verbatim: record.completionTokens?.formatted()
                            ?? String(localized: "Not reported")
                    )
                }
                Text(
                    "Runtime timings measure the proxy; the first upstream frame may contain metadata, and does not prove first-token or engine queue time."
                ).font(.caption).foregroundStyle(.secondary)
            }
            if let evidence = record.provenance {
                SparkRequestProvenanceSection(evidence: evidence)
            }
            if record.outcome == "running" {
                Section {
                    Button(
                        cancelled ? "Cancellation requested" : "Cancel request",
                        role: .destructive
                    ) {
                        Task { cancelled = await cancel() }
                    }.disabled(cancelled)
                } footer: {
                    Text(
                        "Cancellation closes the proxy stream; engine termination cannot be independently confirmed."
                    )
                }
            }
        }
        .navigationTitle("Request details")
    }
    private func timing(_ name: String, _ milliseconds: Double?) -> some View {
        LabeledContent(name) {
            Text(verbatim: SparkInferenceExperiencePresentation.latency(milliseconds))
        }
    }
}

struct SparkRequestProvenanceSection: View {
    let evidence: SparkRequestDeploymentEvidence
    var body: some View {
        Section("Deployment evidence") {
            LabeledContent("Recipe revision") { Text(verbatim: evidence.recipeRevision) }
            LabeledContent("Model revision") { Text(verbatim: evidence.sourceRevision) }
            LabeledContent("Engine") { Text(verbatim: evidence.engineRecipe) }
            LabeledContent("Runtime") { Text(verbatim: evidence.runtimeVersion) }
            LabeledContent("Context limit") {
                Text(
                    verbatim: evidence.contextLength?.formatted()
                        ?? String(localized: "Not reported")
                )
            }
            LabeledContent("Sequence limit") {
                Text(
                    verbatim: evidence.maxSequences?.formatted()
                        ?? String(localized: "Not reported")
                )
            }
            DisclosureGroup(String(localized: "Recipe and image digests")) {
                Text(verbatim: evidence.recipeDigest).textSelection(.enabled)
                Text(verbatim: evidence.engineImage).textSelection(.enabled)
            }.font(.caption)
            Text(
                "This records the admitted recipe; installed model bytes, tokenizer, template, driver and hardware topology are not independently attested."
            )
            .font(.caption).foregroundStyle(.secondary)
        }
    }
}
