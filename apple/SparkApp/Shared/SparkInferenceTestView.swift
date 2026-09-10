import SwiftUI

struct SparkInferenceTestView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: SparkInferenceTestModel

    init(target: SparkInferenceTestTarget) {
        _model = State(
            initialValue: SparkInferenceTestModel(
                target: target,
                history: SparkInferenceRunHistory()
            )
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(verbatim: model.target.chat.modelName)
                            .font(.title2.bold())
                        Label {
                            Text(verbatim: model.target.chat.displayName)
                        } icon: {
                            Image(systemName: "desktopcomputer")
                        }
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        Text("Send one small request to the loaded model and see how it responds.")
                            .foregroundStyle(.secondary)
                        LabeledContent("Profile") {
                            Text(
                                verbatim: model.target.profileID
                                    ?? String(localized: "Not reported")
                            )
                            .multilineTextAlignment(.trailing)
                        }
                        .font(.callout)
                    }

                    if let error = model.history?.errorMessage {
                        Text(verbatim: error).foregroundStyle(.secondary)
                    }
                    if model.phase != .ready {
                        result
                    }

                    if !model.answer.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Test response")
                                .font(.headline)
                            Text(verbatim: model.answer)
                                .textSelection(.enabled)
                        }
                    }
                    if !model.reasoning.isEmpty {
                        DisclosureGroup(String(localized: "Thinking")) {
                            Text(verbatim: model.reasoning)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, 8)
                        }
                    }

                    VStack(alignment: .leading, spacing: 7) {
                        Text("One short request, limited to 1,024 generated tokens.")
                        Text(
                            "Timing starts when this device requests the test stream, including its connection checks and queue time. Readiness checks before and after the stream are excluded. Thinking counts as first output."
                        )
                        Text("Other work on the Spark can affect these times.")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: 640, alignment: .leading)
                .padding(24)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Test inference")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    if let history = model.history {
                        NavigationLink {
                            SparkInferenceRunHistoryView(history: history, target: model.target) {
                                _ in model.start()
                            }
                        } label: {
                            Label("Measurements", systemImage: "clock.arrow.circlepath")
                        }
                        .disabled(model.phase.isRunning)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack {
                    if model.phase.isRunning {
                        Button("Cancel test", role: .cancel) { model.cancel() }
                            .buttonStyle(.bordered)
                    } else {
                        Button {
                            model.start()
                        } label: {
                            Text(model.phase == .ready ? "Start test" : "Test again")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    Spacer()
                }
                .frame(maxWidth: 640)
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity)
                .background(.bar)
            }
        }
        .frame(minWidth: 320, idealWidth: 600, minHeight: 400, idealHeight: 640)
        .onDisappear { model.cancel() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { model.cancel() }
        }
    }

    private var result: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                if model.phase.isRunning {
                    ProgressView()
                } else {
                    Image(systemName: resultSymbol)
                        .foregroundStyle(model.phase == .succeeded ? Color.green : Color.secondary)
                        .accessibilityHidden(true)
                }
                Text(statusTitle)
                    .font(.headline)
            }
            if let error = model.errorMessage {
                Text(error)
                    .foregroundStyle(.secondary)
            } else if model.phase == .limited {
                Text("The model returned output and reached the test's token limit.")
                    .foregroundStyle(.secondary)
            }
            if model.firstOutputSeconds != nil || model.elapsedSeconds != nil {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 140), alignment: .leading)],
                    spacing: 14
                ) {
                    measurement(
                        String(localized: "First output"),
                        seconds: model.firstOutputSeconds
                    )
                    if model.elapsedSeconds != nil {
                        measurement(String(localized: "Elapsed"), seconds: model.elapsedSeconds)
                        count(String(localized: "Input tokens"), value: model.usage?.prompt)
                        count(String(localized: "Output tokens"), value: model.usage?.completion)
                    }
                }
                if model.usage == nil, !model.phase.isRunning {
                    Text("The model did not report usable token counts for this request.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Placement", value: String(localized: "Fixed target"))
                LabeledContent("Engine queue time", value: String(localized: "Not reported"))
                if let runtime = model.runtimeRecord {
                    metric(
                        String(localized: "Admission check"),
                        value: SparkInferenceExperiencePresentation.latency(runtime.admissionMs)
                    )
                    metric(
                        String(localized: "First upstream frame"),
                        value: SparkInferenceExperiencePresentation.latency(runtime.firstFrameMs)
                    )
                    Text("Runtime timings measure the proxy, not engine queue or first-token time.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                LabeledContent("Reported serving name") {
                    Text(verbatim: model.reportedServingName ?? String(localized: "Not reported"))
                        .multilineTextAlignment(.trailing)
                }
                .font(.caption)
                Text(
                    "The serving name is reported by the engine; it is not independent proof of the model revision."
                ).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 14))
    }

    private func measurement(_ title: String, seconds: TimeInterval?) -> some View {
        metric(
            title,
            value: SparkInferenceExperiencePresentation.latency(seconds.map { $0 * 1_000 })
        )
    }

    private func count(_ title: String, value: Int?) -> some View {
        metric(title, value: value?.formatted() ?? String(localized: "Not reported"))
    }

    private func metric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(verbatim: value).font(.headline).monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }

    private var statusTitle: String {
        switch model.phase {
        case .ready: String(localized: "Ready to test")
        case .checking: String(localized: "Checking loaded model")
        case .waiting: String(localized: "Waiting for output")
        case .receiving: String(localized: "Receiving output")
        case .succeeded: String(localized: "Test completed")
        case .limited: String(localized: "Output received")
        case .cancelled: String(localized: "Test cancelled")
        case .failed: String(localized: "Test did not complete")
        }
    }

    private var resultSymbol: String {
        switch model.phase {
        case .succeeded: "checkmark.circle.fill"
        case .cancelled: "stop.circle"
        case .failed: "exclamationmark.circle"
        default: "waveform"
        }
    }
}
