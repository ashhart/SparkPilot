import Foundation
import Observation
import SparkAPI
import SparkCore
import SparkDesignSystem
import SparkLanguageModel
import SparkLibrary
import SparkSecurity
import SparkTransport

public struct SparkChatTarget: Identifiable, Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let nodeID: SparkNodeID
    public let clusterID: SparkClusterID?
    public let route: URL
    public let tlsFingerprint: String
    public let authorityFingerprint: String
    public let modelID: String
    public let modelName: String
    public let contextLength: Int?
    public let visionSupported: Bool?
    /// The route this answer travels, so §52.1's disclosure can name the transport.
    public let connection: TargetConnectionState
    public var selectionID: String { id + "/" + modelID }

    public init(
        id: String,
        displayName: String,
        nodeID: SparkNodeID,
        clusterID: SparkClusterID? = nil,
        route: URL,
        tlsFingerprint: String,
        authorityFingerprint: String,
        modelID: String,
        modelName: String,
        contextLength: Int? = nil,
        visionSupported: Bool? = nil,
        connection: TargetConnectionState = .connectedWiFi
    ) {
        self.id = id
        self.displayName = displayName
        self.nodeID = nodeID
        self.clusterID = clusterID
        self.route = route
        self.tlsFingerprint = tlsFingerprint
        self.authorityFingerprint = authorityFingerprint
        self.modelID = modelID
        self.modelName = modelName
        self.contextLength = contextLength
        self.visionSupported = visionSupported
        self.connection = connection
    }

    /// Where this answer runs and how it gets here (§52.1, UX matrix copy rule 6).
    public var executionLocation: ExecutionLocationValue {
        let transport: SparkExecutionTransport =
            switch connection {
            case .connectedDirect: .directCable
            case .connectedRemote: .remote
            default: .localNetwork
            }
        if clusterID != nil {
            return .sparkCluster(nodeCount: 0, name: displayName, transport: transport)
        }
        return .spark(nodeName: displayName, transport: transport)
    }

    public var executionAccessibilityLabel: String {
        String(
            localized: .executionTargetAndModel(
                target: executionLocation.label,
                model: modelName
            )
        )
    }
}

public enum SparkChatUnavailableReason: String, Error, Equatable, Sendable {
    case noActiveModel
    case modelLoading
    case checkingStatus
    case offline
    case identityMismatch
    case authenticationUnavailable
    case routeUnavailable
    case notShared
}

public struct SparkChatUnavailableTarget: Equatable, Sendable {
    public let name: String
    public let reason: SparkChatUnavailableReason
    /// The library entry, when known, so an empty state can open that Spark's models directly.
    public let id: String?

    public init(name: String, reason: SparkChatUnavailableReason, id: String? = nil) {
        self.name = name
        self.reason = reason
        self.id = id
    }
}

public enum SparkChatEmptyState: Equatable, Sendable {
    case emptyFleet
    case noActiveModel
    case modelLoading
    case checkingStatus
    case offline
    case identityMismatch
    case authenticationUnavailable
    case notShared

    public var title: String {
        switch self {
        case .emptyFleet: String(localized: "Add a Spark to start chatting")
        case .noActiveModel: String(localized: "No model is ready for chat")
        case .modelLoading: String(localized: "Model is starting")
        case .checkingStatus: String(localized: "Checking model status")
        case .offline: String(localized: "Your Sparks are offline")
        case .identityMismatch: String(localized: "A Spark's identity changed")
        case .authenticationUnavailable: String(localized: "Pair this device again")
        case .notShared: String(localized: "This model isn't shared with you")
        }
    }

    public var message: String {
        switch self {
        case .emptyFleet:
            String(localized: "Chats become available after this device pairs with a Spark.")
        case .noActiveModel:
            String(localized: "Load an installed chat model on a paired Spark, then return here.")
        case .modelLoading:
            String(
                localized:
                    "The model is loading on your Spark. Chat will become available when it is ready."
            )
        case .checkingStatus:
            String(
                localized:
                    "SparkPilot is refreshing the Spark's model status before sending a message."
            )
        case .offline:
            String(
                localized:
                    "The last model information is old. Reconnect to a Spark before sending a message."
            )
        case .identityMismatch:
            String(
                localized:
                    "Spark refused to use a saved route because it no longer proves the paired identity."
            )
        case .authenticationUnavailable:
            String(
                localized: "This device has no usable signing or trust record for the saved Spark."
            )
        case .notShared:
            String(
                localized:
                    "The owner hasn't shared the model that's running on this Spark. Ask them to share it, or to load one they've shared, then check again."
            )
        }
    }

    public var symbol: String {
        switch self {
        case .emptyFleet: "plus.rectangle.on.rectangle"
        case .noActiveModel: "square.stack.3d.up.slash"
        case .modelLoading: "hourglass"
        case .checkingStatus: "arrow.clockwise"
        case .offline: "wifi.slash"
        case .identityMismatch: "exclamationmark.shield"
        case .authenticationUnavailable: "person.badge.key"
        case .notShared: "person.crop.circle.badge.xmark"
        }
    }
}

public struct SparkChatTargetCatalogue: Equatable, Sendable {
    public let targets: [SparkChatTarget]
    public let installedTargets: [SparkChatTarget]
    public let pairedTargetCount: Int
    public let unavailableTargets: [SparkChatUnavailableTarget]

    public init(
        targets: [SparkChatTarget],
        pairedTargetCount: Int,
        unavailableTargets: [SparkChatUnavailableTarget] = [],
        installedTargets: [SparkChatTarget] = []
    ) {
        self.targets = targets
        self.pairedTargetCount = pairedTargetCount
        self.unavailableTargets = unavailableTargets
        self.installedTargets = installedTargets
    }

    public var modelChoices: [SparkChatTarget] {
        targets
            + installedTargets.filter { installed in
                !targets.contains { $0.selectionID == installed.selectionID }
            }
    }

    public static let empty = SparkChatTargetCatalogue(targets: [], pairedTargetCount: 0)

    /// Replace every target on the ready target's Spark with the one that just became ready.
    public func replacingTargets(on ready: SparkChatTarget) -> SparkChatTargetCatalogue {
        SparkChatTargetCatalogue(
            targets: targets.filter { $0.id != ready.id } + [ready],
            pairedTargetCount: pairedTargetCount,
            unavailableTargets: unavailableTargets,
            installedTargets: installedTargets
        )
    }

    public var emptyState: SparkChatEmptyState? {
        guard targets.isEmpty else { return nil }
        guard pairedTargetCount > 0 else { return .emptyFleet }
        if unavailableTargets.contains(where: { $0.reason == .identityMismatch }) {
            return .identityMismatch
        }
        if unavailableTargets.contains(where: { $0.reason == .modelLoading }) {
            return .modelLoading
        }
        if unavailableTargets.contains(where: { $0.reason == .checkingStatus }) {
            return .checkingStatus
        }
        if unavailableTargets.contains(where: { $0.reason == .noActiveModel }) {
            return .noActiveModel
        }
        if unavailableTargets.contains(where: { $0.reason == .notShared }) {
            return .notShared
        }
        if unavailableTargets.contains(where: {
            $0.reason == .offline || $0.reason == .routeUnavailable
        }) {
            return .offline
        }
        return .authenticationUnavailable
    }
}

@MainActor
public protocol SparkChatTargetProviding: AnyObject {
    func catalogue() -> SparkChatTargetCatalogue
    func voiceTargets() -> [SparkVoiceTarget]
    func refresh() async
}

extension SparkChatTargetProviding {
    public func refresh() async {}
    public func voiceTargets() -> [SparkVoiceTarget] {
        catalogue().targets.map(SparkVoiceTarget.init)
    }
}

extension SparkChatUnavailableReason {
    public var title: String {
        switch self {
        case .noActiveModel: String(localized: "No model loaded")
        case .modelLoading: String(localized: "Model loading")
        case .checkingStatus: String(localized: "Checking")
        case .offline: String(localized: "Offline")
        case .identityMismatch: String(localized: "Identity changed")
        case .authenticationUnavailable: String(localized: "Needs pairing")
        case .routeUnavailable: String(localized: "No route")
        case .notShared: String(localized: "Not shared")
        }
    }

    public var symbol: String {
        switch self {
        case .noActiveModel: "square.stack.3d.up.slash"
        case .modelLoading: "hourglass"
        case .checkingStatus: "arrow.clockwise"
        case .offline, .routeUnavailable: "wifi.slash"
        case .identityMismatch: "exclamationmark.shield"
        case .authenticationUnavailable: "person.badge.key"
        case .notShared: "person.crop.circle.badge.xmark"
        }
    }
}

extension SparkChatEmptyState {
    /// The one tap each empty state ends in.
    public enum Action: Equatable, Sendable {
        case addSpark, loadModel, checkAgain, reviewSparks, pairAgain
    }

    public var action: Action {
        switch self {
        case .emptyFleet: .addSpark
        case .noActiveModel: .loadModel
        case .modelLoading, .checkingStatus, .offline, .notShared: .checkAgain
        case .identityMismatch: .reviewSparks
        case .authenticationUnavailable: .pairAgain
        }
    }

    public var actionTitle: String {
        switch self {
        case .emptyFleet: String(localized: "Add Spark")
        case .noActiveModel: String(localized: "Load a model")
        case .modelLoading, .checkingStatus, .notShared: String(localized: "Check Again")
        case .offline: String(localized: "Look Again")
        case .identityMismatch: String(localized: "Review Sparks")
        case .authenticationUnavailable: String(localized: "Pair Again")
        }
    }
}
