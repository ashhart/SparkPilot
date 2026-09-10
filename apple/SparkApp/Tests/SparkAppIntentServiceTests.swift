import Foundation
import SparkAPI
import SparkCore
import SparkIntents
import SparkLibrary
import SparkSecurity
import Testing
@testable import SparkAppComposition

private actor IntentExecutorSpy: SparkIntentExecuting {
    private(set) var generatedTargetIDs: [String] = []
    private(set) var generatedTransports: [SparkTransportKind] = []
    private(set) var generatedMaxTokens: [Int] = []
    private(set) var loadedTargetIDs: [String] = []
    private(set) var modelTargetIDs: [String] = []
    private let failure: (any Error)?

    init(failure: (any Error)? = nil) {
        self.failure = failure
    }

    func status(for target: SparkIntentTarget) async throws -> SparkIntentRuntimeStatus {
        SparkIntentRuntimeStatus(
            loadedModelName: "Compact 8B",
            memoryUsedPercent: 42,
            waitingJobs: 0
        )
    }

    func models(for target: SparkIntentTarget) async throws -> [SparkIntentRuntimeModel] {
        modelTargetIDs.append(target.id)
        return [
            SparkIntentRuntimeModel(
                id: "open/compact-8b",
                displayName: "Compact 8B",
                installed: true,
                safeProfileID: "balanced"
            )
        ]
    }

    func generate(
        on target: SparkIntentTarget,
        userText: String,
        instructions: String?,
        maxTokens: Int
    ) async throws -> String {
        if let failure { throw failure }
        generatedTargetIDs.append(target.id)
        generatedTransports.append(target.transport)
        generatedMaxTokens.append(maxTokens)
        return "Answered by \(target.displayName)"
    }

    func loadModel(
        _ model: SparkIntentRuntimeModel,
        on target: SparkIntentTarget
    ) async throws -> String {
        loadedTargetIDs.append(target.id)
        return "load-operation"
    }

    func unloadActiveModel(on target: SparkIntentTarget) async throws -> String {
        return "unload-operation"
    }

    // Reject durable-analysis calls from foreground intent tests; SparkAnalysisIntentServiceTests covers those executor methods.
    func supportsDurableAnalysis(on target: SparkIntentTarget) async throws -> Bool {
        Issue.record("the foreground intents must not consult the analysis capability")
        return false
    }

    func startAnalysis(
        on target: SparkIntentTarget,
        input: SparkFileAnalysisInput,
        instruction: String
    ) async throws -> UUID {
        Issue.record("the foreground intents must not start a durable analysis")
        return UUID()
    }

    func analysisOutcome(
        jobID: UUID,
        on target: SparkIntentTarget
    ) async throws -> SparkAnalysisHandoff {
        Issue.record("the foreground intents must not read a durable analysis")
        return .running(jobID: jobID.uuidString)
    }

    func cancelAnalysis(jobID: UUID, on target: SparkIntentTarget) async {
        Issue.record("the foreground intents must not cancel a durable analysis")
    }
}

@MainActor
private func intentService(
    role: String?,
    executor: any SparkIntentExecuting
) -> SparkAppIntentService {
    let nodeID = SparkNodeID(rawValue: UUID())
    let authority = String(repeating: "b", count: 64)
    let library = SparkLibrary(store: MemoryLibraryStore())
    library.reconcile(
        AuthenticatedTarget(
            nodeID: nodeID,
            clusterID: nil,
            name: "Desk Spark",
            role: .standalone,
            authorityFingerprint: authority,
            displayName: "desk-spark",
            routes: [
                CachedRoute(
                    baseURL: URL(string: "https://192.168.1.20:7443")!,
                    kind: .localWiFi,
                    lastSuccess: Date(timeIntervalSince1970: 100)
                )
            ],
            reachedAt: Date(timeIntervalSince1970: 100)
        )
    )
    let trust = NodeTrust(
        nodeID: nodeID.rawValue.uuidString.lowercased(),
        nodeName: "Desk Spark",
        tlsFingerprint: String(repeating: "a", count: 64),
        authorityFingerprint: authority,
        authorityPublicKey: "fixture",
        pairedAt: .now,
        localDeviceRole: role
    )
    // Presence proofs are exercised separately; the role tests must never reach LocalAuthentication.
    return SparkAppIntentService(
        library: library,
        trustLookup: { requestedID in requestedID == trust.nodeID ? trust : nil },
        executor: executor,
        authenticateModelChange: {}
    )
}

@MainActor
@Test func observerPermissionStopsAskBeforeAnyPromptLeavesTheDevice() async {
    let executor = IntentExecutorSpy()
    let service = intentService(role: "observer", executor: executor)

    await #expect(throws: SparkIntentError.self) {
        _ = try await service.ask("private prompt", targetID: nil)
    }
    #expect(await executor.generatedTargetIDs.isEmpty)
}

@MainActor
@Test func modelSuggestionsExcludeTargetsThatCannotOperateModels() async throws {
    let executor = IntentExecutorSpy()
    let service = intentService(role: "user", executor: executor)

    #expect(try await service.knownModels().isEmpty)
    #expect(await executor.modelTargetIDs.isEmpty)
}

@Test func capabilityDenialIsNotMisreportedAsDeviceRevocation() async {
    let target = intentTarget(id: "node:one", name: "Desk Spark")
    let service = SparkAppIntentService(
        targets: { [target] },
        executor: IntentExecutorSpy(
            failure: APIError(.local(message: "forbidden"), statusCode: 403, code: "ROLE_FORBIDDEN")
        )
    )

    do {
        _ = try await service.ask("hello", targetID: target.id)
        Issue.record("expected permission denial")
    } catch let error as SparkIntentError {
        #expect(error == .permissionDenied)
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}

@Test func askIsBoundedForTheShortSystemIntentPath() async throws {
    let target = intentTarget(id: "node:one", name: "Desk Spark")
    let executor = IntentExecutorSpy()
    let service = SparkAppIntentService(targets: { [target] }, executor: executor)

    _ = try await service.ask("short question", targetID: target.id)
    #expect(await executor.generatedMaxTokens == [SparkAppIntentService.askOutputLimitTokens])

    await #expect(throws: SparkIntentError.self) {
        _ = try await service.ask(
            String(repeating: "x", count: SparkAppIntentService.askInputLimitBytes + 1),
            targetID: target.id
        )
    }
    #expect(await executor.generatedTargetIDs.count == 1)
}

@MainActor
@Test func productionTargetLoadingNeverRoutesAnIntentThroughRemoteAccess() async throws {
    let nodeID = SparkNodeID(rawValue: UUID())
    let authority = String(repeating: "b", count: 64)
    let library = SparkLibrary(store: MemoryLibraryStore())
    library.reconcile(
        AuthenticatedTarget(
            nodeID: nodeID,
            clusterID: nil,
            name: "Desk Spark",
            role: .standalone,
            authorityFingerprint: authority,
            displayName: "desk-spark",
            routes: [
                CachedRoute(
                    baseURL: URL(string: "https://remote.example:7443")!,
                    kind: .privateOverlay,
                    lastSuccess: Date(timeIntervalSince1970: 300)
                ),
                CachedRoute(
                    baseURL: URL(string: "https://192.168.1.20:7443")!,
                    kind: .localWiFi,
                    lastSuccess: Date(timeIntervalSince1970: 100)
                ),
            ],
            reachedAt: Date(timeIntervalSince1970: 300)
        )
    )
    let trust = NodeTrust(
        nodeID: nodeID.rawValue.uuidString.lowercased(),
        nodeName: "Desk Spark",
        tlsFingerprint: String(repeating: "a", count: 64),
        authorityFingerprint: authority,
        authorityPublicKey: "fixture",
        pairedAt: .now
    )
    let executor = IntentExecutorSpy()
    let service = SparkAppIntentService(
        library: library,
        trustLookup: { requestedID in requestedID == trust.nodeID ? trust : nil },
        executor: executor
    )

    _ = try await service.ask("hello", targetID: nil)

    #expect(await executor.generatedTransports == [.localWiFi])
}

@MainActor
@Test func reconcilingAProductionTargetRefreshesShortcutParameters() {
    let library = SparkLibrary(store: MemoryLibraryStore())
    let nodeID = SparkNodeID(rawValue: UUID())
    var refreshCount = 0
    let outcome = SparkIntentEntityReconciler.reconcile(
        AuthenticatedTarget(
            nodeID: nodeID,
            clusterID: nil,
            name: "Desk Spark",
            role: .standalone,
            authorityFingerprint: nil,
            displayName: "desk-spark",
            routes: [
                CachedRoute(
                    baseURL: URL(string: "https://desk-spark.local:7443")!,
                    kind: .localWiFi
                )
            ],
            reachedAt: .now
        ),
        into: library,
        refreshShortcutParameters: { refreshCount += 1 }
    )

    #expect(outcome.entry.coordinatorNodeID == nodeID)
    #expect(refreshCount == 1)
}

private func intentTarget(
    id: String,
    name: String,
    clusterID: UUID? = nil
) -> SparkIntentTarget {
    SparkIntentTarget(
        id: id,
        displayName: name,
        nodeID: SparkNodeID(rawValue: UUID()),
        clusterID: clusterID.map(SparkClusterID.init(rawValue:)),
        route: URL(string: "https://spark.local:7443")!,
        transport: .localWiFi,
        tlsFingerprint: String(repeating: "a", count: 64),
        authorityFingerprint: String(repeating: "b", count: 64)
    )
}

@Test func anExplicitClusterIntentUsesThatAuthenticatedLogicalTarget() async throws {
    let node = intentTarget(id: "node:one", name: "Desk Spark")
    let cluster = intentTarget(
        id: "cluster:two",
        name: "Lab Cluster",
        clusterID: UUID()
    )
    let executor = IntentExecutorSpy()
    let service = SparkAppIntentService(
        targets: { [node, cluster] },
        executor: executor,
        authenticateModelChange: {}
    )

    let answer = try await service.ask("hello", targetID: cluster.id)
    let operationID = try await service.loadModel("open/compact-8b", targetID: cluster.id)

    #expect(answer == "Answered by Lab Cluster")
    #expect(operationID == "load-operation")
    #expect(await executor.generatedTargetIDs == [cluster.id])
    #expect(await executor.loadedTargetIDs == [cluster.id])
}

@Test func anOmittedTargetNeverChoosesArbitrarilyFromSeveralSparks() async {
    let service = SparkAppIntentService(
        targets: {
            [
                intentTarget(id: "node:one", name: "One"),
                intentTarget(id: "node:two", name: "Two"),
            ]
        },
        executor: IntentExecutorSpy()
    )

    await #expect(throws: SparkIntentError.self) {
        _ = try await service.ask("hello", targetID: nil)
    }
}

@Test func modelEntitiesKeepTheirLogicalTargetWhenSeveralSparksShareAModelID() async throws {
    let first = intentTarget(id: "node:one", name: "One")
    let second = intentTarget(id: "cluster:two", name: "Two", clusterID: UUID())
    let service = SparkAppIntentService(
        targets: { [first, second] },
        executor: IntentExecutorSpy()
    )

    let models = try await service.knownModels()

    #expect(models.count == 2)
    #expect(Set(models.map(\.targetID)) == Set([first.id, second.id]))
    #expect(Set(models.map(\.modelID)) == ["open/compact-8b"])
    #expect(Set(models.map(\.id)).count == 2)
}

@MainActor
private final class RecordingAppLockAuthenticator: AppLockAuthenticating {
    private(set) var reasons: [String] = []
    var failure: AppLockAuthenticationError?
    func availableMethod() -> AppLockMethod { .faceID }
    func authenticate(reason: String) async throws {
        reasons.append(reason)
        if let failure { throw failure }
    }
}

/// M-3: a model change from Siri proves presence even with app lock off; reads keep the lock gate.
@MainActor
@Test func modelChangingIntentsProvePresenceEvenWhenAppLockIsOff() async throws {
    let defaults = try #require(UserDefaults(suiteName: "intent-presence-\(UUID().uuidString)"))
    defaults.removeObject(forKey: AppLockModel.enabledKey)
    let authenticator = RecordingAppLockAuthenticator()
    let executor = IntentExecutorSpy()
    let target = SparkIntentTarget(
        id: "desk",
        displayName: "Desk Spark",
        nodeID: SparkNodeID(rawValue: UUID()),
        route: URL(string: "https://192.168.1.20:7443")!,
        transport: .localWiFi,
        tlsFingerprint: String(repeating: "a", count: 64),
        authorityFingerprint: String(repeating: "b", count: 64)
    )
    let service = SparkAppIntentService(
        targets: { [target] },
        executor: executor,
        authenticateAppLock: {
            try await SparkIntentAppLock.authenticate(
                defaults: defaults,
                authenticator: authenticator
            )
        },
        authenticateModelChange: {
            try await SparkIntentAppLock.authenticateModelChange(authenticator: authenticator)
        }
    )

    _ = try await service.status(targetID: target.id)
    _ = try await service.ask("A question", targetID: target.id)
    #expect(authenticator.reasons.isEmpty, "app lock is off, so reads and asks are not prompted")

    _ = try await service.unloadActiveModel(targetID: target.id)
    _ = try await service.loadModel("open/compact-8b", targetID: target.id)
    #expect(
        authenticator.reasons
            == Array(repeating: "Confirm changing the model on your Spark", count: 2)
    )
    #expect(await executor.loadedTargetIDs == [target.id])

    authenticator.failure = .cancelled
    await #expect(throws: AppLockAuthenticationError.cancelled) {
        _ = try await service.loadModel("open/compact-8b", targetID: target.id)
    }
    await #expect(throws: AppLockAuthenticationError.cancelled) {
        _ = try await service.unloadActiveModel(targetID: target.id)
    }
    #expect(
        await executor.loadedTargetIDs == [target.id],
        "a cancelled proof never reaches the Spark"
    )
}

@MainActor
@Test func lockedIntentServiceCannotReachTheNetworkOrPrivateResults() async throws {
    let executor = IntentExecutorSpy()
    let service = SparkAppIntentService(
        targets: {
            Issue.record("Locked intents must not resolve or contact a Spark")
            return []
        },
        executor: executor,
        authenticateAppLock: { throw AppLockAuthenticationError.cancelled },
        authenticateModelChange: { throw AppLockAuthenticationError.cancelled }
    )
    await #expect(throws: AppLockAuthenticationError.cancelled) {
        _ = try await service.loadModel("model", targetID: "target")
    }
    await #expect(throws: AppLockAuthenticationError.cancelled) {
        _ = try await service.unloadActiveModel(targetID: nil)
    }
    await #expect(throws: AppLockAuthenticationError.cancelled) {
        _ = try await service.analysisResult(jobID: UUID().uuidString, targetID: nil)
    }
    #expect(await executor.loadedTargetIDs.isEmpty)
    #expect(await executor.modelTargetIDs.isEmpty)
}
