#if os(macOS)
    import AppKit
    import SwiftUI

    public struct SparkDeveloperToolsView: View {
        @Bindable private var model: SparkDeveloperToolsModel
        @State private var keyVisible = false
        @State private var copied = false
        @Environment(\.dynamicTypeSize) private var dynamicTypeSize

        public init(model: SparkDeveloperToolsModel) {
            self.model = model
        }

        public var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    targetPicker
                    localEndpoint
                    sparkAddress
                    tools
                }
                .frame(maxWidth: 820, alignment: .leading)
                .padding(32)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .navigationTitle("Launch")
            .onAppear { model.refresh() }
            .onChange(of: model.endpoint?.token) { _, _ in
                keyVisible = false
                copied = false
            }
        }

        private var header: some View {
            VStack(alignment: .leading, spacing: 6) {
                Text("Launch with Spark")
                    .font(.largeTitle.bold())
                Text("Choose a running model, then open an agent already connected to it.")
                    .foregroundStyle(.secondary)
            }
        }

        @ViewBuilder
        private var targetPicker: some View {
            if model.catalogue.targets.isEmpty {
                GroupBox {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: model.catalogue.emptyState?.symbol ?? "bolt.slash")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.catalogue.emptyState?.title ?? "No model is ready")
                                .font(.headline)
                            Text(
                                model.catalogue.emptyState?.message
                                    ?? "Start a model on a paired Spark, then return here."
                            )
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
                } label: {
                    Label("Run on", systemImage: "bolt.horizontal.circle")
                        .font(.headline)
                }
            } else {
                GroupBox {
                    Picker("Model", selection: $model.selectedTargetID) {
                        ForEach(model.catalogue.targets) { target in
                            Text(String(localized: .joined(target.modelName, target.displayName)))
                                .tag(Optional(target.id))
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 430, alignment: .leading)
                    .accessibilityHint("Selects the Spark and running model used by launched apps")
                } label: {
                    Label("Run on", systemImage: "bolt.horizontal.circle")
                        .font(.headline)
                }
            }
        }

        private var localEndpoint: some View {
            GroupBox {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Connect another app on this Mac using an OpenAI-compatible API.")
                        .foregroundStyle(.secondary)
                    if let target = model.selectedTarget {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Models available now").font(.headline)
                            Text(target.displayName).foregroundStyle(.secondary)
                            Text(target.modelName).font(.body.weight(.medium))
                            copyRow(
                                String(localized: "Model ID"),
                                value: target.modelID,
                                copyLabel: String(localized: "Copy model ID")
                            )
                            Text(
                                "This endpoint serves the selected running model; load another model in Library to change it."
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                    if let endpoint = model.endpoint {
                        Divider()
                        copyRow(
                            String(localized: "API base URL"),
                            value: endpoint.apiURL.absoluteString,
                            copyLabel: String(localized: "Copy API base URL")
                        )
                        if let port = endpoint.port {
                            copyRow(
                                String(localized: "Port"),
                                value: String(port),
                                copyLabel: String(localized: "Copy port")
                            )
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("API key").font(.subheadline.weight(.medium))
                            if keyVisible {
                                Text(endpoint.token)
                                    .font(.system(.body, design: .monospaced))
                                    .textSelection(.enabled)
                                    .privacySensitive()
                            } else {
                                Text("Hidden until revealed").foregroundStyle(.secondary)
                            }
                            HStack {
                                Button(keyVisible ? "Hide key" : "Reveal key") {
                                    keyVisible.toggle()
                                }
                                Button("Copy API key") { copy(endpoint.token) }
                            }
                        }
                        ViewThatFits(in: .horizontal) {
                            HStack { endpointActions(endpoint) }
                            VStack(alignment: .leading) { endpointActions(endpoint) }
                        }
                        Text(
                            "Keep SparkPilot open while connected; stopping the endpoint or changing the selection invalidates this key."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        Button("Stop endpoint", role: .destructive) { model.stopEndpoint() }
                    } else {
                        if model.endpointStarting {
                            ProgressView(String(localized: "Starting local endpoint…"))
                            Button("Cancel") { model.stopEndpoint() }
                        } else {
                            Button("Start local endpoint") {
                                Task { await model.startEndpoint() }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.selectedTarget == nil)
                        }
                        if let error = model.endpointError {
                            Text(error).foregroundStyle(.red)
                        }
                    }
                    if copied {
                        Label("Copied to clipboard", systemImage: "checkmark")
                            .font(.caption)
                            .accessibilityAddTraits(.updatesFrequently)
                    }
                    Button("Refresh models") {
                        model.refresh()
                    }
                    .disabled(model.endpointStarting)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
            } label: {
                Label("Local API", systemImage: "network")
                    .font(.headline)
            }
        }

        /// The Spark's own OpenAI-compatible address on the path in use, and what changes when the path does.
        @ViewBuilder
        private var sparkAddress: some View {
            if let target = model.selectedTarget, let address = SparkAPIAddress(route: target.route)
            {
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        SparkConnectionPathBadge(path: address.path)
                        copyRow(
                            String(localized: "Spark API base URL"),
                            value: address.baseURLText,
                            copyLabel: String(localized: "Copy Spark API base URL")
                        )
                        Text(address.note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(SparkAPIAddress.bridgeNote)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(SparkAPIAddress.harnessNote)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
                } label: {
                    Label("Spark address", systemImage: address.path.symbol)
                        .font(.headline)
                }
            }
        }

        @ViewBuilder
        private func endpointActions(_ endpoint: SparkIntegrationEndpoint) -> some View {
            if let target = model.selectedTarget {
                Button("Copy setup command") {
                    copy(endpoint.environmentCommand(modelID: target.modelID))
                }
                .help(
                    String(
                        localized:
                            "Sets OPENAI_BASE_URL, OPENAI_API_KEY, and OPENAI_MODEL in your shell"
                    )
                )
            }
            Button("Copy models command") { copy(endpoint.modelsCommand) }
                .help(
                    String(
                        localized: "Copies an authenticated curl request to list the running models"
                    )
                )
        }

        private func copyRow(_ title: String, value: String, copyLabel: String) -> some View {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title).font(.subheadline.weight(.medium))
                    Button {
                        copy(value)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .accessibilityLabel(copyLabel)
                }
                Text(value)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        private func copy(_ value: String) {
            NSPasteboard.general.clearContents()
            if NSPasteboard.general.setString(value, forType: .string) {
                copied = true
            }
        }

        private var tools: some View {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(SparkDeveloperTool.allCases.enumerated()), id: \.element) {
                    index,
                    tool in
                    toolRow(tool)
                    if index < SparkDeveloperTool.allCases.count - 1 { Divider() }
                }
            }
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(.separator.opacity(0.45), lineWidth: 0.5)
            }
        }

        private func toolRow(_ tool: SparkDeveloperTool) -> some View {
            ViewThatFits(in: .horizontal) {
                toolRow(tool, stacksAction: false)
                toolRow(tool, stacksAction: true)
            }
        }

        @ViewBuilder
        private func toolRow(_ tool: SparkDeveloperTool, stacksAction: Bool) -> some View {
            let content = HStack(alignment: .top, spacing: 14) {
                Image(systemName: tool.symbol)
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(.tint)
                    .frame(width: 36, height: 36)
                    .background(.tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(tool.name).font(.headline)
                    Text(statusText(tool) ?? tool.summary)
                        .font(.subheadline)
                        .foregroundStyle(statusColor(tool))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !stacksAction { Spacer(minLength: 20) }
            }
            let action = Button {
                Task { await model.launch(tool) }
            } label: {
                if model.state(for: tool) == .starting {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Launch", systemImage: "arrow.up.forward.app")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.selectedTarget == nil || model.state(for: tool) == .starting)
            .accessibilityLabel(String(localized: .launchDeveloperTool(tool.name)))

            Group {
                if stacksAction || dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 12) {
                        content
                        action
                    }
                } else {
                    HStack(spacing: 14) {
                        content
                        action
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }

        private func statusText(_ tool: SparkDeveloperTool) -> String? {
            switch model.state(for: tool) {
            case .idle: nil
            case .starting: String(localized: "Starting the secure local bridge…")
            case .launched:
                String(
                    localized: .openedWithDeveloperModel(
                        model.selectedTarget?.modelName ?? String(localized: "the selected model")
                    )
                )
            case .failed(let message): message
            }
        }

        private func statusColor(_ tool: SparkDeveloperTool) -> Color {
            switch model.state(for: tool) {
            case .failed: .red
            case .launched: .green
            default: .secondary
            }
        }
    }
#endif
