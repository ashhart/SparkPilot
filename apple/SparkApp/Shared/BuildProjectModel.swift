import Foundation
import Observation
import SparkAPI
import SparkLibrary
import SparkSecurity

public struct BuildTarget: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let nodeID: String
    public let route: URL
    public let tlsFingerprint: String
    public let authorityFingerprint: String
    public let authorityPublicKey: String
}

public struct SavedBuild: Codable, Identifiable, Sendable, Equatable {
    public let id: String
    public let targetID: String
    public let projectName: String
    public var status: String
    public var updatedAt: String
    public var exitState: String?
    public var diagnostics: [String]
    public var screenshots: [SavedBuildArtifact]
}

public struct SavedBuildArtifact: Codable, Identifiable, Sendable, Equatable {
    public let artifactID: String
    public let relativePath: String
    public let sha256: String

    public var id: String { artifactID.isEmpty ? relativePath : artifactID }

    public init(artifactID: String, relativePath: String, sha256: String) {
        self.artifactID = artifactID
        self.relativePath = relativePath
        self.sha256 = sha256
    }

    public init(from decoder: any Decoder) throws {
        if let legacy = try? decoder.singleValueContainer().decode(String.self) {
            self.init(artifactID: "", relativePath: legacy, sha256: "")
            return
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            artifactID: try values.decode(String.self, forKey: .artifactID),
            relativePath: try values.decode(String.self, forKey: .relativePath),
            sha256: try values.decode(String.self, forKey: .sha256)
        )
    }
}

public protocol BuildClientCreating: Sendable {
    @MainActor func client(for target: BuildTarget) throws -> any BuildProjectNetworking
}

public struct PairedBuildClientFactory: BuildClientCreating {
    public init() {}

    @MainActor
    public func client(for target: BuildTarget) throws -> any BuildProjectNetworking {
        guard let nodeID = UUID(uuidString: target.nodeID) else { throw BuildProjectError.noTarget }
        let signer = try DeviceIdentityStore.loadOrCreateSigner(nodeID: nodeID)
        return try BuildClient(
            baseURL: target.route,
            pin: target.tlsFingerprint,
            signer: signer
        )
    }
}

@MainActor
@Observable
public final class BuildProjectModel {
    private static let savedBuildsKey = "spark.project-builds.v1"
    public private(set) var targets: [BuildTarget] = []
    public var selectedTargetID: String? {
        didSet {
            guard selectedTargetID != oldValue else { return }
            projectsGeneration = UUID()
            projectsTask?.cancel()
            pollTask?.cancel()
            client = nil
            projects = []
            selectedProjectID = nil
            isLoading = false
            problem = nil
        }
    }
    public private(set) var projects: [GeneratedAPI.Project] = []
    public var selectedProjectID: String?
    public var commit = ""
    public var sourceSHA256 = ""
    public var scheme = "SparkApp"
    public var configuration = "Debug"
    public var destination = "platform=macOS"
    public var runsTests = true
    public private(set) var builds: [SavedBuild] = []
    public private(set) var isLoading = false
    public private(set) var isSubmitting = false
    public private(set) var problem: String?

    private let library: SparkLibrary
    private let clients: any BuildClientCreating
    private let trustStore: NodeTrustStore
    private let defaults: UserDefaults
    private var client: (any BuildProjectNetworking)?
    private var pollTask: Task<Void, Never>?
    private var projectsTask: Task<[GeneratedAPI.Project], Error>?
    private var projectsGeneration = UUID()

    public init(
        library: SparkLibrary,
        clients: any BuildClientCreating = PairedBuildClientFactory(),
        trustStore: NodeTrustStore = NodeTrustStore(),
        defaults: UserDefaults = .standard
    ) {
        self.library = library
        self.clients = clients
        self.trustStore = trustStore
        self.defaults = defaults
        builds = Self.loadBuilds(defaults: defaults)
        refreshTargets()
    }

    public var canSubmit: Bool { submitBlockReason == nil && !isSubmitting }

    /// QA-12, QA-25: whether this screen has no Spark at all or none it can sign in to.
    public var accessGate: SparkAccessGate {
        .resolve(savedSparks: library.entries.count, usableTargets: targets.count)
    }

    /// QA-13: the first thing Queue Build is still waiting for, in the owner's words; nil when it can submit.
    public var submitBlockReason: String? {
        if selectedProjectID == nil {
            return String(localized: "Choose a project on a Spark this device can reach.")
        }
        if !commit.isLowercaseBuildHex(count: 40) {
            return String(localized: "Enter the 40-character Git commit in lower-case hex.")
        }
        if !sourceSHA256.isLowercaseBuildHex(count: 64) {
            return String(localized: "Enter the 64-character source SHA-256 in lower-case hex.")
        }
        if scheme.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return String(localized: "Name the Xcode scheme to build.")
        }
        return nil
    }

    public func refreshTargets() {
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
    }

    public func selectTarget(_ id: String?) async {
        pollTask?.cancel()
        projectsTask?.cancel()
        projectsGeneration = UUID()
        selectedTargetID = id
        client = nil
        projects = []
        selectedProjectID = nil
        await refreshProjects()
    }

    public func refreshProjects() async {
        projectsTask?.cancel()
        let generation = UUID()
        projectsGeneration = generation
        guard let target = selectedTarget else {
            isLoading = false
            // QA-12: name Builds and the real gate rather than sending the owner to pair a Spark that is already paired.
            problem =
                switch accessGate {
                case .noSparkSaved:
                    String(localized: "Pair a Spark before queueing a build.")
                case .noUsableSpark:
                    String(
                        localized:
                            "None of your saved Sparks is signed in on this device. Open one from Home, then come back to queue a build."
                    )
                case .ready:
                    nil
                }
            return
        }
        isLoading = true
        defer {
            if projectsGeneration == generation {
                isLoading = false
                projectsTask = nil
            }
        }
        do {
            let client = try clients.client(for: target)
            let request = Task { try await client.projects() }
            projectsTask = request
            let loaded = try await request.value
            guard !Task.isCancelled, projectsGeneration == generation,
                selectedTarget == target
            else { return }
            self.client = client
            projects = loaded
            if selectedProjectID.flatMap({ id in projects.first { $0.id == id } }) == nil {
                selectedProjectID = projects.first?.id
            }
            problem = nil
            await refreshBuilds()
            guard projectsGeneration == generation, selectedTarget == target else { return }
            if let targetID = selectedTargetID,
                builds.contains(where: { $0.targetID == targetID && Self.isActive($0.status) })
            {
                startPolling()
            }
        } catch {
            guard !Task.isCancelled, projectsGeneration == generation,
                selectedTarget == target
            else { return }
            problem = String(localized: "Projects could not be loaded from this Spark.")
        }
    }

    public func submit() async {
        guard canSubmit, let projectID = selectedProjectID,
            let project = projects.first(where: { $0.id == projectID }),
            let targetID = selectedTargetID
        else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            let client = try activeClient()
            let submission = try await client.submitTracked(
                .init(
                    projectId: projectID,
                    commit: commit,
                    sourceSha256: sourceSHA256,
                    scheme: scheme,
                    configuration: configuration,
                    destination: destination,
                    actions: runsTests ? [.build, .test] : [.build],
                    timeoutSeconds: 1_800,
                    requirements: .init(
                        platform: .macOS,
                        architecture: "arm64",
                        signingRequired: false
                    )
                ),
                idempotencyKey: UUID()
            )
            builds.insert(
                SavedBuild(
                    id: submission.buildID,
                    targetID: targetID,
                    projectName: project.name,
                    status: "queued",
                    updatedAt: Self.timestamp(Date()),
                    exitState: nil,
                    diagnostics: [],
                    screenshots: []
                ),
                at: 0
            )
            persist()
            problem = nil
            startPolling()
        } catch {
            problem = String(localized: "The build could not be submitted.")
        }
    }

    public func refreshBuilds() async {
        guard let client = try? activeClient(), let targetID = selectedTargetID else {
            return
        }
        let pending = builds.filter { $0.targetID == targetID }
        for existing in pending {
            guard let job = try? await client.job(buildID: existing.id),
                let index = builds.firstIndex(where: { $0.id == existing.id })
            else { continue }
            builds[index] = Self.saved(job, targetID: targetID, projectName: existing.projectName)
        }
        persist()
    }

    public func screenshotData(
        build: SavedBuild,
        artifact: SavedBuildArtifact
    ) async throws -> Data {
        guard !artifact.artifactID.isEmpty, artifact.sha256.isLowercaseBuildHex(count: 64)
        else { throw BuildProjectError.invalidArtifact }
        guard let target = targets.first(where: { $0.id == build.targetID }) else {
            throw BuildProjectError.noTarget
        }
        let artifactClient =
            if target.id == selectedTargetID {
                try activeClient()
            } else {
                try clients.client(for: target)
            }
        return try await artifactClient.artifact(
            buildID: build.id,
            artifactID: artifact.artifactID,
            expectedSHA256: artifact.sha256
        )
    }

    private var selectedTarget: BuildTarget? {
        selectedTargetID.flatMap { id in targets.first { $0.id == id } }
    }

    private func activeClient() throws -> any BuildProjectNetworking {
        if let client { return client }
        guard let target = selectedTarget else { throw BuildProjectError.noTarget }
        let made = try clients.client(for: target)
        client = made
        return made
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self else { return }
                await self.refreshBuilds()
                let targetID = self.selectedTargetID
                if !self.builds.contains(where: {
                    $0.targetID == targetID && Self.isActive($0.status)
                }) {
                    return
                }
            }
        }
    }

    private func persist() {
        defaults.set(try? JSONEncoder().encode(builds), forKey: Self.savedBuildsKey)
    }

    private static func loadBuilds(defaults: UserDefaults) -> [SavedBuild] {
        guard let data = defaults.data(forKey: savedBuildsKey) else { return [] }
        return (try? JSONDecoder().decode([SavedBuild].self, from: data)) ?? []
    }

    private static func saved(
        _ job: GeneratedAPI.BuildJob,
        targetID: String,
        projectName: String
    ) -> SavedBuild {
        let result = job.result?.evidence
        return SavedBuild(
            id: job.buildId,
            targetID: targetID,
            projectName: projectName,
            status: job.status.rawValue,
            updatedAt: job.updatedAt,
            exitState: result?.exitState.rawValue,
            diagnostics: result?.diagnostics.map(\.message) ?? [],
            screenshots: result?.artifacts.filter { $0.kind == .screenshot }.map {
                SavedBuildArtifact(
                    artifactID: $0.artifactId,
                    relativePath: $0.relativePath,
                    sha256: $0.sha256
                )
            } ?? []
        )
    }

    private static func isActive(_ status: String) -> Bool {
        ["queued", "claimed", "running"].contains(status)
    }

    private static func timestamp(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}

private enum BuildProjectError: Error { case noTarget, invalidArtifact }

extension String {
    fileprivate func isLowercaseBuildHex(count: Int) -> Bool {
        self.count == count
            && utf8.allSatisfy {
                (48...57).contains($0) || (97...102).contains($0)
            }
    }
}
