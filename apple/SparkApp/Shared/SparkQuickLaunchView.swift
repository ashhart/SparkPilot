import SparkAPI
import SparkCore
import SparkLibrary
import SwiftUI

public struct SparkQuickLaunchView: View {
    @State private var model: SparkQuickLaunchModel
    @State private var showsConfiguration = false
    @State private var thinkingBudget = 256
    @Environment(\.dismiss) private var dismiss

    public init(library: SparkLibrary) {
        _model = State(initialValue: SparkQuickLaunchModel(library: library))
    }
    public init(model: SparkQuickLaunchModel) { _model = State(initialValue: model) }

    public var body: some View {
        NavigationStack {
            Form {
                if model.ready {
                    Section {
                        Label("Model ready for chat", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
                Section("Model") {
                    #if os(macOS)
                        if let target = model.selectedTarget {
                            LabeledContent("Spark", value: target.displayName)
                        }
                    #endif
                    if model.choices.isEmpty, !model.isBusy {
                        Text("No installed models are available on a connected Spark.")
                    } else {
                        Menu {
                            ForEach(model.choices, id: \.selectionID) { target in
                                Button {
                                    Task { await model.select(target.selectionID) }
                                } label: {
                                    Text(.pair(target.displayName, target.modelName))
                                    if target.selectionID == model.selectedID {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    if let target = model.selectedTarget {
                                        Text(target.modelName).foregroundStyle(.primary)
                                            .fixedSize(horizontal: false, vertical: true)
                                        Text(target.displayName).font(.subheadline)
                                            .foregroundStyle(.secondary)
                                    } else {
                                        Text("Spark and model")
                                    }
                                }
                                Spacer()
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityLabel("Spark and model")
                        .disabled(model.isBusy)
                    }
                }
                if !model.profiles.isEmpty {
                    Section("Your launch preset") {
                        if !model.isBusy && !model.ready {
                            SparkContextTip(.launchPreset)
                        }
                        if let profile = model.selectedProfile {
                            LabeledContent("Preset", value: profile.displayName)
                        }
                        if let note = model.presetNote {
                            Text(note).font(.caption).foregroundStyle(.secondary)
                        }
                        if let target = model.selectedTarget {
                            Picker(
                                "Thinking budget",
                                selection: Binding(
                                    get: { thinkingBudget },
                                    set: {
                                        thinkingBudget = $0
                                        SparkModelDefaults.saveThinkingBudget(
                                            $0,
                                            targetID: target.id,
                                            modelID: target.modelID
                                        )
                                    }
                                )
                            ) {
                                Text("Off").tag(0)
                                Text("Quick · 256 tokens").tag(256)
                                Text("Balanced · 1,024 tokens").tag(1024)
                                Text("Deep · 4,096 tokens").tag(4096)
                            }
                            .pickerStyle(.menu)
                            .accessibilityIdentifier("spark.model.thinking-budget")
                            .disabled(model.isBusy)
                            Text(
                                "Limits thinking before the answer in chats and new Oh My Pi or OpenCode sessions from this device."
                            )
                            .font(.caption).foregroundStyle(.secondary)
                        }
                        if let profile = model.selectedProfile,
                            profile.supportedIdlePolicies?.isEmpty == false
                        {
                            SparkModelIdleControls(setting: $model.idleSetting, profile: profile)
                                .id([model.selectedID, profile.id])
                                .disabled(model.isBusy)
                            if model.idleSettingChanged {
                                Button("Save unload setting") {
                                    Task { await model.saveIdleSetting() }
                                }
                                .disabled(model.isBusy)
                                .accessibilityIdentifier("spark.model.unload-save")
                            }
                        }
                        DisclosureGroup(
                            String(localized: "Change preset"),
                            isExpanded: $showsConfiguration
                        ) {
                            Picker("Preset", selection: $model.selectedProfileID) {
                                ForEach(model.profiles.filter(\.safe)) { profile in
                                    if profile.id == model.defaultProfileID {
                                        Text(.defaultPresetName(profile.displayName))
                                            .tag(Optional(profile.id))
                                    } else {
                                        Text(profile.displayName).tag(Optional(profile.id))
                                    }
                                }
                            }
                            #if os(iOS)
                                .pickerStyle(.navigationLink)
                            #endif
                            .disabled(model.isBusy)
                            if let profile = model.selectedProfile {
                                LabeledContent(
                                    "Context tokens",
                                    value: profile.maxModelLength.formatted()
                                )
                                LabeledContent(
                                    "Maximum simultaneous requests",
                                    value: profile.maxSequences.formatted()
                                )
                            }
                            Text("Your selection is remembered when you launch this model.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Section {
                    if model.isLoading {
                        VStack(alignment: .leading, spacing: 8) {
                            if let fraction = model.progress?.fraction {
                                ProgressView(value: fraction)
                                    .progressViewStyle(.linear)
                                    .accessibilityLabel("Model launch progress")
                            } else {
                                ProgressView().progressViewStyle(.linear)
                                    .accessibilityLabel("Waiting for model launch progress")
                            }
                            Text(model.statusLine).font(.callout)
                            if let detail = model.progress?.detail {
                                Text(detail).font(.caption).foregroundStyle(.secondary)
                            }
                            Text(
                                "You can close this; the model keeps loading on the Spark and the dashboard shows its progress."
                            )
                            .font(.caption).foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Model launch progress")
                        .accessibilityValue(model.statusLine)
                        .accessibilityIdentifier("spark.model.launch.progress")
                    } else if model.isBusy {
                        ProgressView(model.statusLine)
                    }
                    if let title = model.errorTitle {
                        Text(title).font(.headline).foregroundStyle(.red)
                    }
                    if let error = model.errorMessage { Text(error).foregroundStyle(.red) }
                }
            }
            .scrollDismissesKeyboard(.immediately)
            .safeAreaInset(edge: .bottom) {
                Group {
                    if model.ready {
                        Button("Ask your Spark") {
                            guard let target = model.readyTarget else { return }
                            dismiss()
                            NotificationCenter.default.post(
                                name: .sparkModelReadyChatRequested,
                                object: target
                            )
                        }
                        .accessibilityIdentifier("spark.model.launch.chat")
                    } else {
                        Button {
                            Task { await model.prepare() }
                        } label: {
                            VStack(spacing: 2) {
                                Text("Launch model")
                                if let profile = model.selectedProfile {
                                    Text(profile.displayName).font(.caption)
                                }
                            }
                        }
                        .accessibilityIdentifier("spark.model.launch.preset")
                        .disabled(model.isBusy || model.selectedProfile?.safe != true)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
                .padding().background(.bar)
            }
            .formStyle(.grouped)
            .navigationTitle("Launch model")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        model.cancelReview()
                        dismiss()
                    }
                }
            }
            .onChange(of: model.selectedID, initial: true) { _, _ in
                if let target = model.selectedTarget {
                    thinkingBudget = SparkModelDefaults.thinkingBudget(
                        targetID: target.id,
                        modelID: target.modelID
                    )
                }
            }
            .task {
                showsConfiguration = !model.launchOnOpen
                await model.start()
            }
            .sheet(
                item: Binding(
                    get: { model.pendingPlan?.confirmation == nil ? nil : model.pendingPlan },
                    set: { if $0 == nil, model.pendingPlan != nil { model.cancelReview() } }
                )
            ) { plan in
                if let confirmation = plan.confirmation {
                    ModelActionConfirmationView(
                        confirmation: confirmation,
                        cancel: model.cancelReview,
                        apply: { Task { await model.apply() } }
                    )
                }
            }
        }
    }
}
