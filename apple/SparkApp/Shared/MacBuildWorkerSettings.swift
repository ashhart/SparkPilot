#if os(macOS)
    import Foundation
    import Observation
    import SparkAPI
    import SparkLibrary
    import SparkSecurity
    import SwiftUI

    public protocol BuildWorkerControllerCreating: Sendable {
        @MainActor func make(
            target: BuildTarget,
            workerID: UUID,
            snapshot: @escaping BuildWorkerController.SnapshotHandler
        ) async throws -> BuildWorkerController
    }

    public struct PairedBuildWorkerFactory: BuildWorkerControllerCreating {
        public init() {}

        @MainActor
        public func make(
            target: BuildTarget,
            workerID: UUID,
            snapshot: @escaping BuildWorkerController.SnapshotHandler
        ) async throws -> BuildWorkerController {
            try Task.checkCancellation()
            guard let nodeID = UUID(uuidString: target.nodeID) else {
                throw URLError(.badServerResponse)
            }
            let deviceKey = try DeviceKeyFactory.makeSigner()
            let deviceID = DeviceIdentityStore.loadOrCreateDeviceID().uuidString.lowercased()
            let requestSigner = SparkRequestSigner(
                deviceID: deviceID,
                nodeID: nodeID,
                signingKey: deviceKey
            )
            let client = try BuildClient(
                baseURL: target.route,
                pin: target.tlsFingerprint,
                signer: requestSigner
            )
            let projects = try await client.projects()
            try Task.checkCancellation()
            let capabilities = try await XcodeWorkerCapabilityProbe().load()
            try Task.checkCancellation()
            let applicationSupport = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let workspace =
                applicationSupport
                .appendingPathComponent("SparkPilot", isDirectory: true)
                .appendingPathComponent("BuildWorker", isDirectory: true)
                .appendingPathComponent(target.nodeID, isDirectory: true)
            // Clean crash-left private source before resuming digest-bound leases with a fresh fetch.
            if FileManager.default.fileExists(atPath: workspace.path) {
                try FileManager.default.removeItem(at: workspace)
            }
            try FileManager.default.createDirectory(
                at: workspace,
                withIntermediateDirectories: true
            )
            return BuildWorkerController(
                nodeID: target.nodeID,
                workerID: workerID,
                client: client,
                trust: BuildWorkerTrust(
                    authorityPublicKey: target.authorityPublicKey,
                    authorityFingerprint: target.authorityFingerprint,
                    workerID: workerID,
                    allowedProjectIDs: Set(projects.map { $0.id.lowercased() })
                ),
                capabilities: capabilities,
                sourceFetcher: GitBuildSourceFetcher(),
                executor: XcodeBuildExecutor(),
                evidenceSigner: BuildEvidenceSigner(key: deviceKey),
                workspaceRoot: workspace,
                snapshotHandler: snapshot
            )
        }
    }

    @MainActor
    @Observable
    public final class BuildWorkerSettingsModel {
        public private(set) var targets: [BuildTarget] = []
        public var selectedTargetID: String?
        public private(set) var isEnabled = false
        public private(set) var isPreparing = false
        public private(set) var snapshot: BuildWorkerSnapshot?
        public private(set) var problem: String?

        private let library: SparkLibrary
        private let trustStore: NodeTrustStore
        private let factory: any BuildWorkerControllerCreating
        private let defaults: UserDefaults
        private var controller: BuildWorkerController?
        private var preparation: Task<Void, Never>?
        private var generation = UUID()

        public init(
            library: SparkLibrary,
            trustStore: NodeTrustStore = NodeTrustStore(),
            factory: any BuildWorkerControllerCreating = PairedBuildWorkerFactory(),
            defaults: UserDefaults = .standard
        ) {
            self.library = library
            self.trustStore = trustStore
            self.factory = factory
            self.defaults = defaults
            refreshTargets()
        }

        public var phaseText: String {
            guard let snapshot else {
                return isEnabled ? String(localized: "Preparing") : String(localized: "Off")
            }
            return switch snapshot.phase {
            case .disabled: String(localized: "Off")
            case .registering: String(localized: "Registering")
            case .online: String(localized: "Online")
            case .busy: String(localized: "Building")
            case .offline: String(localized: "Offline")
            case .revoked: String(localized: "Revoked")
            case .failed: String(localized: "Failed")
            }
        }

        public func refreshTargets() {
            let previous = selectedTarget
            targets = library.entries.compactMap { entry in
                guard let node = entry.coordinatorNodeID,
                    let route = entry.preferredRoute?.baseURL,
                    let trust = try? trustStore.trust(
                        forNode: node.rawValue.uuidString.lowercased()
                    )
                else { return nil }
                return BuildTarget(
                    id: entry.id,
                    name: entry.displayName,
                    nodeID: node.rawValue.uuidString.lowercased(),
                    route: route,
                    tlsFingerprint: trust.tlsFingerprint,
                    authorityFingerprint: trust.authorityFingerprint,
                    authorityPublicKey: trust.authorityPublicKey
                )
            }
            if selectedTargetID.flatMap({ id in targets.first { $0.id == id } }) == nil {
                selectedTargetID = targets.first?.id
            }
            if previous != selectedTarget {
                let oldController = invalidatePreparation()
                Task { await oldController?.setEnabled(false) }
            }
            loadEnabledState()
        }

        public func selectTarget(_ targetID: String?) async {
            let oldController = invalidatePreparation()
            selectedTargetID = targetID
            loadEnabledState()
            let current = generation
            await oldController?.setEnabled(false)
            guard generation == current, selectedTargetID == targetID else { return }
            if isEnabled { await prepareAndStart() }
        }

        public func setEnabled(_ enabled: Bool) async {
            guard let target = selectedTarget else {
                problem = String(
                    localized: "Pair a Spark before enabling this Mac as a build worker."
                )
                return
            }
            isEnabled = enabled
            BuildWorkerIdentityStore.setEnabled(enabled, nodeID: target.nodeID, defaults: defaults)
            if enabled {
                await prepareAndStart()
            } else {
                let oldController = invalidatePreparation()
                problem = nil
                await oldController?.setEnabled(false)
            }
        }

        private func invalidatePreparation() -> BuildWorkerController? {
            generation = UUID()
            preparation?.cancel()
            preparation = nil
            isPreparing = false
            let oldController = controller
            controller = nil
            snapshot = nil
            return oldController
        }

        public func resumeIfEnabled() async {
            refreshTargets()
            if isEnabled { await prepareAndStart() }
        }

        private var selectedTarget: BuildTarget? {
            selectedTargetID.flatMap { id in targets.first { $0.id == id } }
        }

        private func loadEnabledState() {
            guard let target = selectedTarget else {
                isEnabled = false
                return
            }
            isEnabled = BuildWorkerIdentityStore.enabled(nodeID: target.nodeID, defaults: defaults)
        }

        private func prepareAndStart() async {
            if let preparation {
                await preparation.value
                return
            }
            guard isEnabled, controller == nil, let target = selectedTarget else { return }
            let current = generation
            isPreparing = true
            let task = Task { [weak self] in
                guard let self else { return }
                defer {
                    if self.generation == current {
                        self.isPreparing = false
                        self.preparation = nil
                    }
                }
                do {
                    let workerID = BuildWorkerIdentityStore.loadOrCreate(
                        nodeID: target.nodeID,
                        defaults: self.defaults
                    )
                    let made = try await self.factory.make(
                        target: target,
                        workerID: workerID,
                        snapshot: { [weak self] snapshot in
                            guard let self, self.generation == current,
                                self.selectedTarget == target, self.isEnabled
                            else { return }
                            self.snapshot = snapshot
                        }
                    )
                    guard !Task.isCancelled, self.generation == current,
                        self.selectedTarget == target, self.isEnabled
                    else {
                        await made.setEnabled(false)
                        return
                    }
                    self.controller = made
                    self.problem = nil
                    await made.setEnabled(true)
                    guard !Task.isCancelled, self.generation == current,
                        self.selectedTarget == target, self.isEnabled
                    else {
                        await made.setEnabled(false)
                        return
                    }
                } catch {
                    guard !Task.isCancelled, self.generation == current,
                        self.selectedTarget == target, self.isEnabled
                    else { return }
                    self.isEnabled = false
                    BuildWorkerIdentityStore.setEnabled(
                        false,
                        nodeID: target.nodeID,
                        defaults: self.defaults
                    )
                    self.problem = String(
                        localized:
                            "This Mac could not become a build worker. Check Xcode and the Spark connection."
                    )
                }
            }
            preparation = task
            await task.value
        }
    }

    public struct BuildWorkerSettingsView: View {
        @State private var model: BuildWorkerSettingsModel

        public init(model: BuildWorkerSettingsModel) {
            _model = State(initialValue: model)
        }

        public var body: some View {
            @Bindable var model = model
            Form {
                Section {
                    if model.targets.isEmpty {
                        Text("Pair a Spark before enabling build work.")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Spark", selection: $model.selectedTargetID) {
                            ForEach(model.targets) { target in
                                Text(target.name).tag(Optional(target.id))
                            }
                        }
                        .onChange(of: model.selectedTargetID) { _, targetID in
                            Task { await model.selectTarget(targetID) }
                        }
                        Toggle(
                            "Use this Mac as a build worker",
                            isOn: Binding(
                                get: { model.isEnabled },
                                set: { enabled in Task { await model.setEnabled(enabled) } }
                            )
                        )
                        .disabled(model.isPreparing)
                    }
                } footer: {
                    Text(
                        "SparkPilot checks signed, expiring recipes and starts fixed tool executables inside its macOS app sandbox. Xcode projects can contain build scripts and plug-ins, so enable this only for source you trust; stopping the worker terminates its build process tree."
                    )
                }

                if model.isEnabled || model.snapshot != nil {
                    Section("Worker status") {
                        LabeledContent("State", value: model.phaseText)
                        if let id = model.snapshot?.workerID {
                            LabeledContent("Worker", value: id.uuidString.lowercased())
                        }
                        if let buildID = model.snapshot?.activeBuildID {
                            LabeledContent("Current build", value: buildID)
                        }
                        if let message = model.snapshot?.message {
                            Text(message).foregroundStyle(.secondary)
                        }
                    }
                }

                if let problem = model.problem {
                    Section { Label(problem, systemImage: "exclamationmark.triangle.fill") }
                        .foregroundStyle(.orange)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Build Worker")
            .task { await model.resumeIfEnabled() }
        }
    }
#endif
