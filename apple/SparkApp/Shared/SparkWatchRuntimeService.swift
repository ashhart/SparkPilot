import Foundation
import SparkAPI
import SparkCore
import SparkDesignSystem
import SparkIntents
import SparkLibrary
import SparkWatchSupport

@MainActor
final class SparkWatchRuntimeService: SparkWatchServicing {
    private let library: SparkLibrary
    private let appLock: AppLockModel
    private let executionPolicy: SparkExecutionPolicyModel?

    init(
        library: SparkLibrary,
        appLock: AppLockModel,
        executionPolicy: SparkExecutionPolicyModel? = nil
    ) {
        self.library = library
        self.appLock = appLock
        self.executionPolicy = executionPolicy
    }

    func authorize(_ request: SparkWatchRequest) throws {
        if appLock.isEnabled && appLock.isLocked {
            throw SparkWatchFailure("Unlock SparkPilot on your iPhone to use your watch.")
        }
        let policy = executionPolicy ?? SparkExecutionPolicyModel()
        policy.reload()
        if request.command == .ask,
            let reason = policy.decision(for: .localNetwork).explanation
        {
            throw SparkWatchFailure(reason)
        }
    }

    func authorizeInference(role: SparkDeviceRole?) throws {
        let policy = executionPolicy ?? SparkExecutionPolicyModel()
        policy.reload()
        if policy.choice == .myHardwareOnly, role != .owner {
            throw SparkWatchFailure(
                "Your execution policy allows only hardware you own. Choose a Spark where you are the owner."
            )
        }
    }

    func execute(_ request: SparkWatchRequest) async throws -> SparkWatchResponse {
        library.load()
        let service = SparkAppIntentService(
            library: library,
            authenticateAppLock: { [weak self] in
                guard let self else { throw SparkWatchFailure("Open SparkPilot on your iPhone.") }
                try self.authorize(request)
            },
            authenticateModelChange: { [weak self] in
                guard let self, request.command.changesModel else {
                    throw SparkWatchFailure("Confirm the change on your watch.")
                }
                try request.validate(now: Date())
                try self.authorize(request)
            }
        )
        do {
            var response = SparkWatchResponse(id: request.id, phase: .complete)
            switch request.command {
            case .overview:
                response.targets = try await service.knownTargets().map {
                    SparkWatchTarget(
                        id: $0.id,
                        name: $0.displayName,
                        canAsk: $0.allowedActions.contains(.runInference),
                        canManageModels: $0.allowedActions.contains(.operateModels)
                    )
                }
            case .status:
                let target = try await service.target(id: request.targetID, requiring: .readStatus)
                let executor = PinnedSparkIntentExecutor()
                let api = try await executor.authenticatedAPI(for: target)
                async let telemetry = api.telemetry(route: target.route)
                async let catalogue = api.models(route: target.route)
                let (value, models) = try await (telemetry, catalogue)
                response.models = models.items.filter {
                    $0.installState == .installed && $0.profiles.contains(where: \.safe)
                }.map { SparkWatchModel(id: $0.id, targetID: target.id, name: $0.displayName) }
                response.telemetry = SparkWatchTelemetry(
                    targetID: target.id,
                    observedAt: value.observedAt,
                    modelName: value.inference.modelID.map { id in
                        models.items.first { $0.id == id }?.displayName ?? id
                    },
                    modelState: value.inference.state,
                    memoryPercent: value.system.unifiedMemoryTotalBytes > 0
                        ? Double(value.system.unifiedMemoryUsedBytes)
                            / Double(value.system.unifiedMemoryTotalBytes) * 100 : nil,
                    cpuPercent: SparkWatchTelemetry.percent(fraction: value.system.cpuUtilisation),
                    gpuPercent: SparkWatchTelemetry.percent(
                        fraction: value.accelerator.utilisation
                    ),
                    temperatureCelsius: value.accelerator.temperatureCelsius
                        ?? value.system.temperatureCelsius,
                    powerWatts: value.accelerator.powerDrawWatts,
                    queuedRequests: value.inference.queueDepth ?? 0
                )
            case .ask:
                let target = try await service.target(
                    id: request.targetID,
                    requiring: .runInference
                )
                try authorizeInference(role: target.localDeviceRole)
                response.message = try await answer(request.messages, on: target)
            case .load:
                response.operationID = try await service.loadModel(
                    request.modelID ?? "",
                    targetID: request.targetID ?? ""
                )
                response.message = "Model start accepted. Check telemetry for readiness."
            case .stop:
                response.operationID = try await service.unloadActiveModel(
                    targetID: request.targetID
                )
                response.message = "Model stop accepted. Check telemetry for completion."
            case .poll, .cancel:
                throw SparkWatchFailure("This request cannot run directly.")
            }
            return response
        } catch let error as SparkIntentError {
            throw SparkWatchFailure(error.displayMessage)
        } catch let error as SparkWatchFailure {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SparkWatchFailure(SparkAppIntentService.intentError(error).displayMessage)
        }
    }

    private func answer(_ messages: [SparkWatchMessage], on target: SparkIntentTarget) async throws
        -> String
    {
        let api = try await PinnedSparkIntentExecutor().authenticatedAPI(for: target)
        let inference = try await api.activeInference(route: target.route)
        guard let modelID = inference.modelID,
            inference.state == .ready || inference.state == .idle
        else { throw SparkWatchFailure("Start a model on this Spark before sending a message.") }
        let chatTarget = SparkChatTarget(
            id: target.id,
            displayName: target.displayName,
            nodeID: target.nodeID,
            clusterID: target.clusterID,
            route: target.route,
            tlsFingerprint: target.tlsFingerprint,
            authorityFingerprint: target.authorityFingerprint,
            modelID: modelID,
            modelName: modelID
        )
        let stream = try await PinnedSparkChatStreamer().stream(
            target: chatTarget,
            request: ChatCompletionRequest(
                model: modelID,
                messages: [
                    .init(
                        role: "system",
                        content: "Reply concisely for an Apple Watch screen. Use plain text."
                    )
                ]
                    + messages.map { .init(role: $0.role.rawValue, content: $0.text) },
                stream: true,
                maxTokens: 384,
                streamOptionsIncludeUsage: true
            )
        )
        var answer = ""
        var finished = false
        var truncated = false
        for try await event in stream {
            try Task.checkCancellation()
            if case .chunk(_, _, let delta, _, let reason) = event {
                if let delta { answer += delta }
                if let reason {
                    finished = true
                    truncated = reason == "length"
                }
            }
            if case .done = event { finished = true }
            guard answer.utf8.count <= 24_000 else {
                throw SparkWatchFailure(
                    "The reply exceeded the watch limit. Continue on your iPhone."
                )
            }
        }
        guard finished else {
            throw SparkWatchFailure(
                "The connection ended before the reply finished. Please try again."
            )
        }
        guard !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SparkWatchFailure("The model returned an empty reply. Try again.")
        }
        return truncated ? answer + "\n\nReply reached the watch length limit." : answer
    }
}
