import SparkAPI
import SwiftUI

/// What one automation has actually done: the result, and every search and page it used.
public struct SparkAutomationRunsView: View {
    @Bindable var model: SparkAutomationsModel
    let automation: GeneratedAPI.Automation
    let onEdit: () -> Void

    public init(
        model: SparkAutomationsModel,
        automation: GeneratedAPI.Automation,
        onEdit: @escaping () -> Void
    ) {
        self.model = model
        self.automation = automation
        self.onEdit = onEdit
    }

    private var runs: [GeneratedAPI.AutomationRun] { model.runs[automation.id] ?? [] }

    public var body: some View {
        List {
            Section {
                Text(automation.instructions)
                LabeledContent("Next run", value: SparkAutomationCopy.nextRun(automation))
                LabeledContent(
                    "Reads the internet",
                    value: automation.webAccess
                        ? String(localized: "Yes") : String(localized: "No")
                )
                Button("Run now") {
                    Task { await model.runNow(automation.id) }
                }
                .disabled(!model.canManage || model.isChanging)
                .accessibilityIdentifier("spark.automation.run.now")
            }
            if let message = model.errorMessage {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
            Section("History") {
                if runs.isEmpty {
                    Text("This automation has not run yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(runs, id: \.id) { run in
                        NavigationLink {
                            detail(run)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(SparkAutomationCopy.runState(run.state))
                                    .font(.headline)
                                Text(SparkAutomationCopy.absolute(run.startedAt))
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(automation.name)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Edit") { onEdit() }
                    .disabled(!model.canManage)
            }
        }
        .task { await model.loadRuns(for: automation.id) }
        .refreshable { await model.loadRuns(for: automation.id) }
    }

    @ViewBuilder
    private func detail(_ run: GeneratedAPI.AutomationRun) -> some View {
        List {
            Section {
                LabeledContent("State", value: SparkAutomationCopy.runState(run.state))
                LabeledContent("Started", value: SparkAutomationCopy.absolute(run.startedAt))
                if let finished = run.finishedAt {
                    LabeledContent("Finished", value: SparkAutomationCopy.absolute(finished))
                }
                LabeledContent(
                    "Started by",
                    value: run.trigger == .manual
                        ? String(localized: "You") : String(localized: "Its schedule")
                )
            }
            if let text = run.resultText, !text.isEmpty {
                Section("Result") {
                    Text(text)
                        .textSelection(.enabled)
                }
            }
            if let code = run.errorCode {
                Section("Why it stopped") {
                    Text(SparkAutomationCopy.refusal(code))
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                if run.toolCalls.isEmpty {
                    Text("Nothing left your Spark during this run.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(run.toolCalls, id: \.index) { call in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(line(for: call))
                                .font(.callout)
                            if let outcome = SparkAutomationCopy.outcome(of: call) {
                                Text(outcome)
                                    .font(.footnote)
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                }
            } header: {
                Text("What left your Spark")
            } footer: {
                Text(SparkAutomationCopy.robotsNote)
            }
        }
        .navigationTitle(SparkAutomationCopy.absolute(run.startedAt))
    }

    private func line(for call: GeneratedAPI.AutomationToolCall) -> String {
        switch call.tool {
        case .webSearch:
            String(localized: .automationSearched(query: call.query ?? ""))
        case .webFetch:
            String(localized: .automationRead(url: call.url ?? ""))
        case .personalContext:
            String(localized: .automationContextRemoved)
        }
    }
}
