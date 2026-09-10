import SwiftUI

struct SparkInferenceRunHistoryView: View {
    let history: SparkInferenceRunHistory
    let target: SparkInferenceTestTarget
    let reproduce: (SparkInferenceRunRecord) -> Void
    @State private var confirmClear = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                NavigationLink("Runtime request history") {
                    SparkRequestHistoryView(target: target.chat)
                }
                NavigationLink("Check this profile") {
                    SparkQualificationView(target: target)
                }
                Text(
                    "Measurements are stored on this device without prompts, responses or connection details."
                )
                Text("Up to 200 runs are retained for 90 days; a completed run cannot be edited.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = history.errorMessage { Section { Text(verbatim: error) } }
            Section("Local runs") {
                if history.records.isEmpty {
                    Text("No saved measurements yet.").foregroundStyle(.secondary)
                }
                ForEach(history.records) { record in
                    NavigationLink {
                        List {
                            Section {
                                LabeledContent("Model") { Text(verbatim: record.modelID) }
                                LabeledContent("Profile") {
                                    Text(
                                        verbatim: record.profileID
                                            ?? String(localized: "Not reported")
                                    )
                                }
                                LabeledContent("Result") {
                                    Text(verbatim: sparkRequestOutcomeTitle(record.outcome))
                                }
                                LabeledContent("Client first output") {
                                    Text(
                                        verbatim: SparkInferenceExperiencePresentation.latency(
                                            record.firstOutputSeconds.map { $0 * 1000 }
                                        )
                                    )
                                }
                                LabeledContent("Client elapsed") {
                                    Text(
                                        verbatim: SparkInferenceExperiencePresentation.latency(
                                            record.elapsedSeconds.map { $0 * 1000 }
                                        )
                                    )
                                }
                                if record.stateChanged {
                                    Text("The loaded model or profile changed during this run.")
                                }
                            }
                            if let evidence = record.runtimeRecord?.provenance {
                                SparkRequestProvenanceSection(evidence: evidence)
                            }
                            Section {
                                Button("Repeat this diagnostic") {
                                    dismiss()
                                    reproduce(record)
                                }
                                .disabled(
                                    !record.canReproduce || record.modelID != target.chat.modelID
                                        || record.profileID != target.profileID
                                )
                                NavigationLink("Review evidence to share") {
                                    SparkInferenceEvidenceExportView(record: record)
                                }
                            } footer: {
                                Text(
                                    "Repeating sends the same small synthetic request to the current loaded model after fresh identity and readiness checks; it does not restore an old deployment or run unsigned tuning."
                                )
                            }
                            Section {
                                Text(
                                    "This is a diagnostic, not recipe qualification: quality, full context, concurrency, memory and sustained stability still need separate controlled runs."
                                )
                            }
                        }
                        .navigationTitle("Measurement")
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(verbatim: record.modelID).font(.headline)
                            Text(verbatim: sparkRequestOutcomeTitle(record.outcome))
                            Text(record.startedAt, format: .dateTime.month().day().hour().minute())
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section {
                Button("Clear finished measurements", role: .destructive) { confirmClear = true }
            }
        }
        .navigationTitle("Measurements")
        // An alert, because a popover confirmation drops the cancel button it is given.
        .alert(
            "Clear finished measurements?",
            isPresented: $confirmClear
        ) {
            Button("Clear measurements", role: .destructive) { history.clearFinished() }
            Button("Keep measurements", role: .cancel) {}
        } message: {
            Text("Running tests, runtime history and conversations will be kept.")
        }
    }
}

private struct SparkInferenceEvidenceExportView: View {
    let record: SparkInferenceRunRecord
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Review before sharing").font(.title2.bold())
                Text(
                    "This export includes model and recipe details, outcome and measurements; it excludes prompts, answers, timestamps, request IDs, caller IDs, node IDs, names, addresses and credentials."
                )
                if let json = try? record.export.encoded() {
                    Text(verbatim: json).font(.caption.monospaced()).textSelection(.enabled)
                    ShareLink(item: json) {
                        Label("Share reviewed evidence", systemImage: "square.and.arrow.up")
                    }
                } else {
                    Text("Evidence could not be prepared.")
                }
            }.padding(24)
        }
        .navigationTitle("Share measurement")
    }
}
