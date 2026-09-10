import SparkAPI
import SparkLibrary
import SwiftUI

/// Daemon-owned preparation, available independently of app background refresh.
public struct SparkWarmupView: View {
    @State private var model: SparkWarmupModel
    @State private var disabling: WarmupSchedule?
    public init(model: SparkWarmupModel) { self.model = model }
    public init(library: SparkLibrary, targetID: String) {
        model = SparkWarmupModel(library: library, targetID: targetID)
    }

    public var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Text("Have your model ready when you return.")
                Text(
                    "Your Spark runs this once, even with the app closed. If another workload is active or memory is not safe, it skips the warm-up."
                )
                .font(.subheadline).foregroundStyle(.secondary)
            }
            if let message = model.errorMessage {
                Section {
                    Label(message, systemImage: "exclamationmark.circle").foregroundStyle(.red)
                }
            }
            if !model.hasLoaded {
                Section {
                    if model.isWorking {
                        ProgressView(String(localized: "Checking this Spark…"))
                    } else {
                        Button("Try again") { Task { await model.refresh() } }
                    }
                }
            } else if model.models.isEmpty {
                Section {
                    ContentUnavailableView(
                        "No installed model",
                        systemImage: "square.stack.3d.up",
                        description: Text(
                            "Install a signed model with a safe profile before scheduling a warm-up."
                        )
                    )
                }
            } else {
                Section("New warm-up") {
                    Picker("Model", selection: $model.modelID) {
                        ForEach(model.models) { Text($0.displayName).tag($0.id) }
                    }
                    Picker("Preset", selection: $model.profileID) {
                        ForEach(model.profiles) { Text($0.displayName).tag($0.id) }
                    }
                    DatePicker(
                        String(localized: "Start at"),
                        selection: $model.dueDate,
                        in: Date().addingTimeInterval(60)...Date().addingTimeInterval(7 * 86_400),
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    Button {
                        Task { await model.prepareReview() }
                    } label: {
                        Label("Review warm-up", systemImage: "clock.badge.checkmark")
                    }
                    .disabled(!model.canReview)
                }.disabled(model.isWorking)
            }
            if !model.schedules.isEmpty {
                Section("Scheduled and recent") {
                    ForEach(model.schedules) { schedule in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(
                                model.models.first { $0.id == schedule.modelID }?.displayName
                                    ?? schedule.modelID
                            ).font(.headline)
                            Text(
                                schedule.dueDate,
                                format: .dateTime.weekday().day().month().hour().minute()
                            ).font(.subheadline)
                            Text(schedule.statusDescription).font(.subheadline).foregroundStyle(
                                .secondary
                            )
                            if schedule.canDisable {
                                Button("Disable warm-up", role: .destructive) {
                                    disabling = schedule
                                }.disabled(model.isWorking)
                            }
                        }.padding(.vertical, 4)
                    }
                }
            }
        }
        .navigationTitle("Scheduled warm-up")
        .task { await model.refresh() }
        .refreshable { await model.refresh() }
        .sheet(
            isPresented: Binding(
                get: { model.review != nil },
                set: { if !$0 { model.discardReview() } }
            )
        ) {
            if let review = model.review { reviewSheet(review) }
        }
        .alert(
            "Disable this warm-up?",
            isPresented: Binding(get: { disabling != nil }, set: { if !$0 { disabling = nil } })
        ) {
            if let schedule = disabling {
                Button("Disable warm-up", role: .destructive) {
                    disabling = nil
                    Task { await model.disable(schedule) }
                }
            }
            Button("Cancel", role: .cancel) { disabling = nil }
        } message: {
            Text(
                "This cancels a pending warm-up. A load that has already started must be managed from Models."
            )
        }
    }

    private func reviewSheet(_ preview: WarmupPreview) -> some View {
        NavigationStack {
            Form {
                Section("What will happen") {
                    LabeledContent(
                        "Model",
                        value: model.models.first { $0.id == model.modelID }?.displayName
                            ?? model.modelID
                    )
                    LabeledContent(
                        "Preset",
                        value: model.profiles.first { $0.id == model.profileID }?.displayName
                            ?? model.profileID
                    )
                    LabeledContent("Start at") {
                        Text(
                            Date(timeIntervalSince1970: TimeInterval(preview.dueAt)),
                            format: .dateTime.day().month().hour().minute()
                        )
                    }
                    Text(
                        "The Spark checks again before loading. It will never stop or replace another model."
                    )
                    Text(
                        "If the Spark misses this time by more than ten minutes, it skips the warm-up."
                    ).foregroundStyle(.secondary)
                }
                Section("Reviewed preset") {
                    if let weights = preview.review.evidence.weightBytes {
                        LabeledContent("Weights", value: Self.memoryString(weights))
                    }
                    if let cache = preview.review.evidence.kvCacheBytes {
                        let pool = cache + (preview.review.evidence.stateBytes ?? 0)
                        LabeledContent("Context cache", value: Self.memoryString(pool))
                    }
                    if let overhead = preview.review.evidence.engineOverheadBytes {
                        LabeledContent("Engine overhead", value: Self.memoryString(overhead))
                    }
                    if let required = preview.review.evidence.requiredMemoryBytes {
                        LabeledContent(
                            "Engine and cache reservation",
                            value: ByteCountFormatter.string(
                                fromByteCount: Int64(required),
                                countStyle: .memory
                            )
                        )
                    }
                    if let reserve = preview.review.evidence.systemReserveBytes {
                        LabeledContent(
                            "System reserve",
                            value: ByteCountFormatter.string(
                                fromByteCount: Int64(reserve),
                                countStyle: .memory
                            )
                        )
                    }
                    if let recipe = preview.review.recipe {
                        LabeledContent("Recipe revision", value: recipe.recipeRevision)
                    }
                }
                if !preview.review.warnings.isEmpty {
                    Section("Before it starts") {
                        ForEach(Array(preview.review.warnings.enumerated()), id: \.offset) {
                            _,
                            warning in Text(warning.ownerExplanation)
                        }
                    }
                }
                if !preview.review.blockers.isEmpty {
                    Section("Cannot schedule yet") {
                        ForEach(Array(preview.review.blockers.enumerated()), id: \.offset) {
                            _,
                            blocker in Text(blocker.ownerExplanation)
                        }
                    }
                }
                if let error = model.errorMessage { Section { Text(error).foregroundStyle(.red) } }
                Section {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Button {
                            Task { await model.confirm() }
                        } label: {
                            if model.isWorking { ProgressView() } else { Text("Schedule on Spark") }
                        }.disabled(!model.canConfirm(at: context.date))
                    }
                }
            }
            .navigationTitle("Schedule this warm-up?")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { model.discardReview() }.disabled(model.isWorking)
                }
            }
            .interactiveDismissDisabled(model.isWorking)
        }
    }

    private static func memoryString(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }
}
