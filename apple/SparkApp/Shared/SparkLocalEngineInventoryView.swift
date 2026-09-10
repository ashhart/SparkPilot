#if os(macOS)
    import SwiftUI

    struct SparkLocalEngineInventoryView: View {
        @State private var model = SparkLocalEngineInventoryModel()
        @State private var search = ""
        @Environment(\.scenePhase) private var scenePhase

        var body: some View {
            List {
                Section {
                    Picker("Engine", selection: $model.engine) {
                        ForEach(SparkLocalEngine.allCases) { engine in
                            Text(verbatim: engine.title).tag(engine)
                        }
                    }
                    TextField("Local server address", text: $model.address)
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                    Text(
                        "Use the address configured in the engine app; custom ports and IPv6 loopback are supported."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                    if model.engine == .lmStudio {
                        SecureField("API token, if required", text: $model.tokenInput)
                        Toggle(
                            "Remember this token in this Mac's Keychain",
                            isOn: $model.rememberToken
                        )
                        if model.hasSavedToken {
                            Text("A token is saved for this exact address.").font(.caption)
                        }
                        Button("Remove saved token for this address", role: .destructive) {
                            model.forgetToken()
                        }
                    }
                    HStack {
                        if model.isChecking {
                            ProgressView().controlSize(.small)
                            Button("Cancel check") { model.cancel() }
                        } else {
                            Button("Check local models") { model.check() }.buttonStyle(
                                .borderedProminent
                            )
                        }
                        Button("Clear displayed inventory") { model.clear() }
                            .disabled(model.isChecking || model.snapshot == nil)
                    }
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text(verbatim: model.status).font(.caption).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Check an existing engine")
                } footer: {
                    Text(
                        "Only this button contacts the chosen engine: up to three read-only requests, one MB per response and five seconds per request; nothing is installed, loaded, stopped or shared."
                    )
                }
                if let error = model.error {
                    Section {
                        Label {
                            Text(verbatim: error.message)
                        } icon: {
                            Image(systemName: "exclamationmark.circle")
                        }
                    }
                }
                if let snapshot = model.snapshot {
                    Section("Engine reported") {
                        Label("Detected, not shared", systemImage: "eye")
                        LabeledContent("Version") {
                            Text(
                                verbatim: snapshot.engineVersion
                                    ?? String(localized: "Not reported")
                            )
                        }
                        LabeledContent("Inventory API") { Text(verbatim: snapshot.apiContract) }
                        LabeledContent("Observed") {
                            Text(snapshot.observedAt, format: .dateTime.hour().minute().second())
                        }
                        LabeledContent("Available models") {
                            Text(verbatim: snapshot.models.count.formatted())
                        }
                        Text(
                            "A local server address does not prove local-only inference; external engines can use remote services, and this check does not send a prompt."
                        )
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    Section("Models available to this engine") {
                        let matching = snapshot.models.filter {
                            search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)
                                || $0.id.localizedCaseInsensitiveContains(search)
                        }
                        if snapshot.models.isEmpty {
                            Text("The engine reported no available models.").foregroundStyle(
                                .secondary
                            )
                        } else if matching.isEmpty {
                            Text("No models match your search.").foregroundStyle(.secondary)
                        }
                        ForEach(matching) { item in
                            SparkLocalEngineInventoryRow(
                                model: item,
                                loadedInventoryAvailable: snapshot.loadedInventoryAvailable
                            )
                        }
                    }
                } else if !model.isChecking && model.error == nil {
                    Section {
                        ContentUnavailableView(
                            "Check models without changing the engine",
                            systemImage: "desktopcomputer",
                            description: Text(
                                "Choose Ollama or LM Studio and check its local server when you are ready; SparkPilot does not scan automatically."
                            )
                        )
                    }
                }
            }
            .navigationTitle("Models on this Mac")
            .searchable(text: $search, prompt: Text("Find a local model"))
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { model.clear() }
            }
            .onDisappear { model.clear() }
        }
    }

    private struct SparkLocalEngineInventoryRow: View {
        let model: SparkLocalEngineModel
        let loadedInventoryAvailable: Bool
        var body: some View {
            DisclosureGroup {
                LabeledContent("Engine model ID") {
                    Text(verbatim: model.id).textSelection(.enabled)
                }
                LabeledContent("Model type") {
                    Text(
                        verbatim: model.kind == "llm"
                            ? String(localized: "Language model")
                            : model.kind == "embedding"
                                ? String(localized: "Embedding model")
                                : String(localized: "Not reported")
                    )
                }
                LabeledContent("Format") {
                    Text(verbatim: model.format ?? String(localized: "Not reported"))
                }
                LabeledContent("Quantization") {
                    Text(verbatim: model.quantization ?? String(localized: "Not reported"))
                }
                if let bytes = model.sizeBytes {
                    LabeledContent("Model size, reported") {
                        Text(
                            verbatim: ByteCountFormatter.string(
                                fromByteCount: bytes,
                                countStyle: .file
                            )
                        )
                    }
                }
                LabeledContent("Vision") { Text(verbatim: capability(model.reportedVision)) }
                LabeledContent("Tool use") { Text(verbatim: capability(model.reportedToolUse)) }
                if let digest = model.reportedDigest {
                    LabeledContent("Engine-reported manifest digest") {
                        Text(verbatim: digest).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
                LabeledContent(
                    "Complete immutable identity",
                    value: String(localized: "Unverified")
                )
                LabeledContent("Local-only inference", value: String(localized: "Unverified"))
                LabeledContent(
                    "Pool eligibility",
                    value: String(localized: "Not shared or qualified")
                )
                ForEach(model.loadedInstances) { instance in
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Loaded instance").font(.subheadline.bold())
                        Text(verbatim: instance.id).font(.caption).textSelection(.enabled)
                        LabeledContent("Configured context, reported") {
                            Text(
                                verbatim: instance.contextLength?.formatted()
                                    ?? String(localized: "Not reported")
                            )
                        }
                        LabeledContent("Parallel limit, reported") {
                            Text(
                                verbatim: instance.reportedParallelLimit?.formatted()
                                    ?? String(localized: "Not reported")
                            )
                        }
                        if let bytes = instance.reportedMemoryBytes {
                            LabeledContent("Engine memory, reported") {
                                Text(
                                    verbatim: ByteCountFormatter.string(
                                        fromByteCount: bytes,
                                        countStyle: .file
                                    )
                                )
                            }
                        }
                    }.padding(.vertical, 8)
                }
                Text(
                    "Reported capabilities and configured limits have not been tested; loaded state does not reveal active requests or total GPU load."
                )
                .font(.caption).foregroundStyle(.secondary)
            } label: {
                VStack(alignment: .leading, spacing: 5) {
                    Text(verbatim: model.name).font(.headline)
                    Text(
                        loadedInventoryAvailable
                            ? (model.loadedInstances.isEmpty
                                ? String(localized: "Available, not loaded")
                                : String(localized: "Loaded, not shared"))
                            : String(localized: "Loaded state unavailable")
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }.padding(.vertical, 5)
            }
        }
        private func capability(_ value: Bool?) -> String {
            switch value {
            case true: String(localized: "Reported supported; untested")
            case false: String(localized: "Reported unsupported")
            case nil: String(localized: "Not reported")
            }
        }
    }
#endif
