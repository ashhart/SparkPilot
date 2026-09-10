import AppIntents
import Foundation

/// Inject signed production services behind intent protocols so workflows remain testable without hardware (§40.3).
public protocol IntentServicing: Sendable {
    /// Read concise spoken status without loading a model (§40.4).
    func status(targetID: String?) async throws -> SparkStatusSnapshot

    /// Ask a loaded model. Returns the full answer text.
    func ask(_ question: String, targetID: String?) async throws -> String

    /// Summarise/rewrite helpers over the same path.
    func transform(_ text: String, kind: TextTransformKind, targetID: String?) async throws
        -> String

    /// Start a durable model load; returns the operation id.
    func loadModel(_ modelID: String, targetID: String) async throws -> String

    /// Start a durable unload of the active model; returns the operation id.
    func unloadActiveModel(targetID: String?) async throws -> String

    /// Submit selected-file analysis as durable Spark work that may outlive the intent process (§40.2–40.3).
    func analyseFile(
        _ input: SparkFileAnalysisInput,
        instruction: String,
        targetID: String?
    ) async throws -> SparkAnalysisHandoff

    /// Collect a durable analysis by job identifier.
    func analysisResult(jobID: String, targetID: String?) async throws -> SparkAnalysisHandoff

    /// Enumerate entities for parameter resolution (§40.6).
    func knownTargets() async throws -> [IntentTargetSnapshot]
    func knownModels() async throws -> [IntentModelSnapshot]
}

/// Facts the status intent reports (§40.4).
public struct SparkStatusSnapshot: Equatable, Sendable {
    public enum Reachability: String, Sendable {
        case readyLocalNetwork
        case readyDirectCable
        case readyRemote
        case unreachable
    }

    public let nodeName: String
    public let reachability: Reachability
    public let loadedModelName: String?
    public let memoryUsedPercent: Int
    public let waitingJobs: Int

    public init(
        nodeName: String,
        reachability: Reachability,
        loadedModelName: String? = nil,
        memoryUsedPercent: Int = 0,
        waitingJobs: Int = 0
    ) {
        self.nodeName = nodeName
        self.reachability = reachability
        self.loadedModelName = loadedModelName
        self.memoryUsedPercent = memoryUsedPercent
        self.waitingJobs = waitingJobs
    }

    /// Compose complete stable-key status sentences so translators can reorder values without concatenated fragments.
    public var spokenSummary: String {
        [String(localized: reachabilitySentence), String(localized: loadSentence)]
            .joined(separator: " ")
    }

    private var reachabilitySentence: LocalizedStringResource {
        switch reachability {
        case .readyLocalNetwork: .statusReadyLocalNetwork(nodeName)
        case .readyDirectCable: .statusReadyDirectCable(nodeName)
        case .readyRemote: .statusReadyRemote(nodeName)
        case .unreachable: .statusUnreachable(nodeName)
        }
    }

    /// Choose status sentence keys by whether jobs wait, then pluralise the waiting count within that sentence.
    private var loadSentence: LocalizedStringResource {
        switch (loadedModelName, waitingJobs) {
        case (let model?, 0):
            .statusLoadedNoJobs(model: model, memoryPercent: memoryUsedPercent)
        case (let model?, let jobs):
            .statusLoadedWithJobs(
                model: model,
                memoryPercent: memoryUsedPercent,
                waitingJobs: jobs
            )
        case (nil, 0):
            .statusUnloadedNoJobs(memoryPercent: memoryUsedPercent)
        case (nil, let jobs):
            .statusUnloadedWithJobs(memoryPercent: memoryUsedPercent, waitingJobs: jobs)
        }
    }
}

public enum TextTransformKind: String, Sendable {
    case summarise
    case rewrite
    case draftReply
    case draftEmail
}

public enum IntentTargetKind: String, Sendable, Equatable {
    case node
    case cluster
}

public enum IntentTargetAction: String, Sendable, Equatable, Hashable {
    case readStatus
    case runInference
    case operateModels
}

/// Resolve intent targets from trusted local facts while sparkd authorizes every action.
public struct IntentTargetSnapshot: Equatable, Sendable, Identifiable {
    public let id: String
    public let displayName: String
    public let kind: IntentTargetKind
    public let allowedActions: Set<IntentTargetAction>

    public init(
        id: String,
        displayName: String,
        kind: IntentTargetKind = .node,
        allowedActions: Set<IntentTargetAction> = [.readStatus]
    ) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.allowedActions = allowedActions
    }
}

/// Preserve the early node-only type name as an alias while new callers use IntentTargetSnapshot.
public typealias IntentNodeSnapshot = IntentTargetSnapshot

public struct IntentModelSnapshot: Equatable, Sendable, Identifiable {
    public let id: String
    public let modelID: String
    public let targetID: String
    public let displayName: String
    public let installed: Bool
    public let canLoad: Bool

    public init(
        id: String,
        modelID: String,
        targetID: String,
        displayName: String,
        installed: Bool,
        canLoad: Bool = true
    ) {
        self.id = id
        self.modelID = modelID
        self.targetID = targetID
        self.displayName = displayName
        self.installed = installed
        self.canLoad = canLoad
    }
}

/// Intent-facing errors with user-presentable copy (§40.9).
public enum SparkIntentError: Error, Sendable, Equatable {
    case noPairedSpark
    case deviceRevoked
    case offline
    case targetRequired
    case targetUnavailable
    case permissionDenied
    case actionRequiresApp(String)
    case requestTooLarge(limitBytes: Int)
    case modelNotReady(modelID: String)
    case modelNotInstalled(modelID: String)
    case unsupportedFileType(String?)
    case fileHasNoText
    case analysisContinuesOnSpark(jobID: String)
    case analysisNotFinished(jobID: String)
    case analysisJobUnknown(jobID: String)
    case analysisFailed(reason: String)
    case analysisUnsupported

    /// Give each parameterized message one complete stable-key sentence for translation.
    public var displayMessage: String {
        String(localized: resource)
    }

    var resource: LocalizedStringResource {
        switch self {
        case .noPairedSpark: .intentNoPairedSpark
        case .deviceRevoked: .intentDeviceRevoked
        case .offline: .intentOffline
        case .targetRequired: .intentTargetRequired
        case .targetUnavailable: .intentTargetUnavailable
        case .permissionDenied: .intentPermissionDenied
        case .actionRequiresApp(let reason): .intentActionRequiresApp(reason)
        case .requestTooLarge(let limitBytes): .intentRequestTooLarge(limitBytes)
        case .modelNotReady(let modelID): .intentModelNotReady(modelID)
        case .modelNotInstalled(let modelID): .intentModelNotInstalled(modelID)
        // Name a known unsupported file type in recovery guidance.
        case .unsupportedFileType(let type):
            type.map { .intentUnsupportedFileType($0) } ?? .intentUnsupportedFileKind
        case .fileHasNoText: .intentFileHasNoText
        // Name the durable-analysis collection action so a handed-off job remains actionable.
        case .analysisContinuesOnSpark(let jobID): .intentAnalysisContinues(jobID)
        case .analysisNotFinished(let jobID): .intentAnalysisNotFinished(jobID)
        // Describe local validation failures without claiming a Spark request was made.
        case .analysisJobUnknown(let jobID):
            jobID.isEmpty ? .intentJobUnknown : .intentJobUnknownNamed(jobID)
        case .analysisFailed(let reason): .intentAnalysisFailed(reason)
        case .analysisUnsupported: .intentAnalysisUnsupported
        }
    }
}

/// Present owner copy through the system's own error surface: Siri and Shortcuts read a thrown error here, and without this conformance they show a generic failure instead of these sentences.
extension SparkIntentError: CustomLocalizedStringResourceConvertible {
    public var localizedStringResource: LocalizedStringResource { resource }
}

/// Replace the unavailable intent-service default with the app's signed client during composition.
public enum IntentServices {
    private nonisolated(unsafe) static var implementation: (any IntentServicing)?
    private nonisolated(unsafe) static var shortcutParameterRefresh: @Sendable () -> Void = {}

    public static let unavailable = UnavailableIntentServices()

    public static var shared: any IntentServicing {
        implementation ?? unavailable
    }

    /// Install the production implementation (app startup).
    public static func install(
        _ services: any IntentServicing,
        refreshShortcutParameters: @escaping @Sendable () -> Void = {}
    ) {
        implementation = services
        shortcutParameterRefresh = refreshShortcutParameters
        shortcutParameterRefresh()
    }

    /// Refresh dynamic Spark and model choices after the local library changes.
    public static func refreshShortcutParameters() {
        shortcutParameterRefresh()
    }
}

/// Report missing pairing until the app installs real intent services.
public struct UnavailableIntentServices: IntentServicing {
    public init() {}

    public func status(targetID: String?) async throws -> SparkStatusSnapshot {
        throw SparkIntentError.noPairedSpark
    }

    public func ask(_ question: String, targetID: String?) async throws -> String {
        throw SparkIntentError.noPairedSpark
    }

    public func transform(_ text: String, kind: TextTransformKind, targetID: String?) async throws
        -> String
    {
        throw SparkIntentError.noPairedSpark
    }

    public func loadModel(_ modelID: String, targetID: String) async throws -> String {
        throw SparkIntentError.noPairedSpark
    }

    public func unloadActiveModel(targetID: String?) async throws -> String {
        throw SparkIntentError.noPairedSpark
    }

    public func analyseFile(
        _ input: SparkFileAnalysisInput,
        instruction: String,
        targetID: String?
    ) async throws -> SparkAnalysisHandoff {
        throw SparkIntentError.noPairedSpark
    }

    public func analysisResult(
        jobID: String,
        targetID: String?
    ) async throws -> SparkAnalysisHandoff {
        throw SparkIntentError.noPairedSpark
    }

    public func knownTargets() async throws -> [IntentTargetSnapshot] { [] }

    public func knownModels() async throws -> [IntentModelSnapshot] { [] }
}
