import SparkAPI
import SwiftUI

/// Create or change one automation, saying plainly what it will do and what leaves the house.
public struct SparkAutomationEditorView: View {
    @Bindable var model: SparkAutomationsModel
    private let sparkName: String?
    @State private var draft: SparkAutomationDraft
    private let automationID: String?
    private let onFinish: () -> Void
    @Environment(\.dismiss) private var dismiss

    public init(
        model: SparkAutomationsModel,
        draft: SparkAutomationDraft,
        automationID: String?,
        sparkName: String? = nil,
        onFinish: @escaping () -> Void
    ) {
        self.model = model
        self.sparkName = sparkName
        self._draft = State(initialValue: draft)
        self.automationID = automationID
        self.onFinish = onFinish
    }

    public var body: some View {
        NavigationStack {
            Form {
                if let sparkName { Section { LabeledContent("Runs on", value: sparkName) } }
                Section("What it does") {
                    TextField("Name", text: $draft.name)
                        .accessibilityIdentifier("spark.automation.name")
                    TextField(
                        "What should your Spark do?",
                        text: $draft.instructions,
                        axis: .vertical
                    )
                    .lineLimit(3...8)
                    .accessibilityIdentifier("spark.automation.instructions")
                }
                scheduleSection
                Section("Model") {
                    Picker("Use", selection: $draft.modelID) {
                        Text("Choose a model").tag("")
                        if !draft.modelID.isEmpty
                            && !model.installedModels.contains(where: { $0.id == draft.modelID })
                        {
                            Text(draft.modelID).tag(draft.modelID)
                        }
                        ForEach(model.installedModels) { item in
                            Text(item.displayName).tag(item.id)
                        }
                    }
                    .accessibilityIdentifier("spark.automation.model")
                    if let selected = model.installedModels.first(where: { $0.id == draft.modelID })
                    {
                        Picker("Capacity", selection: $draft.profileID) {
                            Text("Automatic").tag(String?.none)
                            ForEach(selected.profiles.filter(\.safe)) { profile in
                                Text(profile.displayName).tag(Optional(profile.id))
                            }
                        }
                    }
                    Text(
                        model.installedModels.isEmpty
                            ? "Download a model in Models, then choose it here."
                            : "Your Spark starts this model when needed; another model already in use is left running."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                webAccessSection
                Section("When it finishes") {
                    Toggle("Notify my devices", isOn: $draft.notify)
                    Text(
                        "Notifications arrive when SparkPilot can check your Spark, including background checks allowed by your device."
                    )
                    .font(.footnote).foregroundStyle(.secondary)
                    Toggle("Run on schedule", isOn: $draft.enabled)
                }
                if let blocker = draft.blocker {
                    Section {
                        Text(blocker)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                if let message = model.errorMessage {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
            }
            .task { await model.loadChoices() }
            .onChange(of: draft.modelID) { _, _ in draft.profileID = nil }
            .navigationTitle(automationID == nil ? "New automation" : "Edit automation")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onFinish()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(!draft.canSave || model.isChanging)
                        .accessibilityIdentifier("spark.automation.save")
                }
            }
        }
    }

    private var scheduleSection: some View {
        Section("When") {
            Picker("Repeats", selection: $draft.repeats) {
                Text("Every day").tag(SparkAutomationDraft.Repeat.daily)
                Text("Weekdays").tag(SparkAutomationDraft.Repeat.weekdays)
                Text("Every few hours").tag(SparkAutomationDraft.Repeat.everyNHours)
                Text("Once a week").tag(SparkAutomationDraft.Repeat.weekly)
                Text("A time I type").tag(SparkAutomationDraft.Repeat.custom)
            }
            .accessibilityIdentifier("spark.automation.repeats")
            switch draft.repeats {
            case .daily, .weekdays:
                timeOfDay
            case .weekly:
                Picker("On", selection: $draft.weekday) {
                    ForEach(0..<7, id: \.self) { day in
                        Text(Self.weekdayNames[day]).tag(day)
                    }
                }
                timeOfDay
            case .everyNHours:
                Stepper(
                    String(localized: .automationEveryHours(count: draft.everyHours)),
                    value: $draft.everyHours,
                    in: 1...23
                )
                Picker("At minute", selection: $draft.minute) {
                    ForEach([0, 15, 30, 45], id: \.self) { Text("\($0)").tag($0) }
                }
            case .custom:
                TextField(
                    "minute hour day-of-month month day-of-week",
                    text: $draft.customExpression
                )
                .autocorrectionDisabled()
                .accessibilityIdentifier("spark.automation.expression")
            }
            LabeledContent("Time zone", value: draft.timezone)
            Text(
                "Your Spark reads this time in your own time zone, and keeps it across clock changes."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }

    private var timeOfDay: some View {
        DatePicker(
            String(localized: "At"),
            selection: Binding(
                get: {
                    var calendar = Calendar.current
                    calendar.timeZone = TimeZone(identifier: draft.timezone) ?? .current
                    return calendar.date(
                        from: DateComponents(
                            year: 2026,
                            month: 1,
                            day: 1,
                            hour: draft.hour,
                            minute: draft.minute
                        )
                    ) ?? .now
                },
                set: { date in
                    var calendar = Calendar.current
                    calendar.timeZone = TimeZone(identifier: draft.timezone) ?? .current
                    draft.hour = calendar.component(.hour, from: date)
                    draft.minute = calendar.component(.minute, from: date)
                }
            ),
            displayedComponents: .hourAndMinute
        )
        .accessibilityIdentifier("spark.automation.time")
    }

    private var webAccessSection: some View {
        Section("Reading the internet") {
            Toggle("Let this automation read the internet", isOn: $draft.webAccess)
                .disabled(model.webAccess?.policy == nil || model.webAccess?.policy == .off)
                .accessibilityIdentifier("spark.automation.web")
            Text(
                "Search queries and page requests leave your Spark. Private-data checks reduce accidental sharing but cannot guarantee that personal details stay out of every query. Leave web access off for private tasks."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
            if model.webAccess?.policy == .off {
                Text(
                    "Model internet access is switched off for this whole Spark. Turn it on below before an automation can read anything."
                )
                .font(.footnote)
                .foregroundStyle(.orange)
            }
        }
    }

    /// Two digits in the reader's own numerals, never a printf format.
    private func clock(_ value: Int) -> String {
        value.formatted(.number.precision(.integerLength(2)).grouping(.never))
    }

    private func save() async {
        let saved: Bool
        if let automationID {
            saved = await model.update(automationID, with: draft)
        } else {
            saved = await model.create(draft)
        }
        if saved {
            onFinish()
            dismiss()
        }
    }

    private static let weekdayNames: [String] = [
        String(localized: "Sunday"), String(localized: "Monday"), String(localized: "Tuesday"),
        String(localized: "Wednesday"), String(localized: "Thursday"), String(localized: "Friday"),
        String(localized: "Saturday"),
    ]
}
