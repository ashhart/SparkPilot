import Foundation

public enum SparkManagedServiceHealth: String, Codable, Equatable, Sendable {
    case healthy, unhealthy, starting, stopped, unknown
}

public struct SparkManagedServiceObservation: Equatable, Sendable {
    public typealias State = SparkManagedServiceHealth
    public let targetID: String
    public let serviceID: String
    public let state: SparkManagedServiceHealth
    public let observedAt: Date

    public init(
        targetID: String,
        serviceID: String,
        state: SparkManagedServiceHealth,
        observedAt: Date
    ) {
        self.targetID = targetID
        self.serviceID = serviceID
        self.state = state
        self.observedAt = observedAt
    }
}

public struct SparkAgentApprovalCandidate: Equatable, Sendable {
    public let changeID: String
    public let reviewDigest: String?
    public let needsReview: Bool

    public init(changeID: String, reviewDigest: String?, needsReview: Bool) {
        self.changeID = changeID
        self.reviewDigest = reviewDigest
        self.needsReview = needsReview
    }
}

public struct SparkAgentApprovalObservation: Equatable, Sendable {
    public let targetID: String
    public let projectID: String
    public let candidates: [SparkAgentApprovalCandidate]
    public let observedAt: Date

    public init(
        targetID: String,
        projectID: String,
        candidates: [SparkAgentApprovalCandidate],
        observedAt: Date
    ) {
        self.targetID = targetID
        self.projectID = projectID
        self.candidates = candidates
        self.observedAt = observedAt
    }
}

extension Notification.Name {
    public static let sparkManagedServiceObservation = Notification.Name(
        "sparkpilot.service.observation"
    )
    public static let sparkAgentApprovalObservation = Notification.Name(
        "sparkpilot.agent.approval.observation"
    )
}

struct SparkServiceHealthCheckpoint: Codable {
    var lastObservedAt: Date
    var armed = false
    var unhealthySince: Date?
    var notifiedIncident: String?
}

struct SparkApprovalCheckpoint: Codable {
    var lastObservedAt: Date
    var reviews: [String: String]
}

/// Only identifiers, review digests and health-transition metadata are retained.
struct SparkActionableNotificationCheckpoint: Codable {
    var services: [String: SparkServiceHealthCheckpoint] = [:]
    var approvals: [String: SparkApprovalCheckpoint] = [:]
    var pending: [SparkLocalNotification] = []

    mutating func observeService(_ observation: SparkManagedServiceObservation, now: Date)
        -> [SparkLocalNotification]
    {
        guard observation.serviceID == "open-webui", fresh(observation.observedAt, now: now) else {
            return []
        }
        let key = "\(observation.targetID).\(observation.serviceID)"
        if let previous = services[key], observation.observedAt <= previous.lastObservedAt {
            return []
        }
        var state =
            services[key] ?? SparkServiceHealthCheckpoint(lastObservedAt: observation.observedAt)
        state.lastObservedAt = observation.observedAt
        defer {
            services[key] = state
            trim()
        }
        switch observation.state {
        case .unknown, .starting, .stopped:
            pending.removeAll {
                $0.targetID == observation.targetID && $0.serviceID == observation.serviceID
            }
            state.armed = false
            state.unhealthySince = nil
            state.notifiedIncident = nil
        case .healthy:
            let incident = state.notifiedIncident
            state.armed = true
            state.unhealthySince = nil
            state.notifiedIncident = nil
            if let incident {
                return [
                    SparkLocalNotification(
                        identifier: "\(key).\(incident).recovered",
                        title: String(localized: "Open WebUI recovered"),
                        body: String(localized: "Open SparkPilot to review the service."),
                        category: SparkNotificationCategories.health,
                        targetID: observation.targetID,
                        serviceID: observation.serviceID
                    )
                ]
            }
        case .unhealthy:
            guard state.armed, state.notifiedIncident == nil else { return [] }
            guard let since = state.unhealthySince else {
                state.unhealthySince = observation.observedAt
                return []
            }
            guard observation.observedAt.timeIntervalSince(since) >= 30 else { return [] }
            let incident = UUID().uuidString.lowercased()
            state.notifiedIncident = incident
            return [
                SparkLocalNotification(
                    identifier: "\(key).\(incident).unhealthy",
                    title: String(localized: "Open WebUI needs attention"),
                    body: String(
                        localized: "Open SparkPilot to review the service and repair options."
                    ),
                    category: SparkNotificationCategories.health,
                    targetID: observation.targetID,
                    serviceID: observation.serviceID
                )
            ]
        }
        return []
    }

    mutating func observeApprovals(_ observation: SparkAgentApprovalObservation, now: Date)
        -> [SparkLocalNotification]
    {
        guard UUID(uuidString: observation.projectID) != nil,
            fresh(observation.observedAt, now: now)
        else { return [] }
        let key = "\(observation.targetID).\(observation.projectID)"
        let previous = approvals[key]
        if let previous, observation.observedAt <= previous.lastObservedAt { return [] }
        var reviews: [String: String] = [:]
        for candidate in observation.candidates.prefix(128) where candidate.needsReview {
            guard UUID(uuidString: candidate.changeID) != nil,
                let digest = candidate.reviewDigest,
                digest.count == 64,
                digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
            else { continue }
            reviews[candidate.changeID.lowercased()] = digest
        }
        pending.removeAll { notification in
            guard notification.targetID == observation.targetID,
                notification.projectID == observation.projectID,
                let changeID = notification.changeID
            else { return false }
            guard let digest = reviews[changeID] else { return true }
            return !notification.identifier.hasSuffix(".\(digest).review")
        }
        approvals[key] = SparkApprovalCheckpoint(
            lastObservedAt: observation.observedAt,
            reviews: reviews
        )
        trim()
        // Baseline historical review requests on launch and notify only for new requests or revisions.
        guard let previous else { return [] }
        return reviews.keys.sorted().compactMap { changeID in
            guard let digest = reviews[changeID], previous.reviews[changeID] != digest else {
                return nil
            }
            return SparkLocalNotification(
                identifier: "\(key).\(changeID).\(digest).review",
                title: String(localized: "An agent change is ready for review"),
                body: String(localized: "Open SparkPilot to review the change before approving."),
                category: SparkNotificationCategories.operation,
                targetID: observation.targetID,
                projectID: observation.projectID,
                changeID: changeID
            )
        }
    }

    mutating func suspendServiceHealth(targetID: String) {
        for key in services.keys where key.hasPrefix("\(targetID).") {
            services[key]?.armed = false
            services[key]?.unhealthySince = nil
            services[key]?.notifiedIncident = nil
        }
        pending.removeAll { $0.targetID == targetID && $0.serviceID != nil }
    }

    mutating func retainTargets(_ identifiers: Set<String>) {
        pending.removeAll { !identifiers.contains($0.targetID) }
        services = services.filter { entry in identifiers.contains { entry.key.hasPrefix("\($0).") }
        }
        approvals = approvals.filter { entry in
            identifiers.contains { entry.key.hasPrefix("\($0).") }
        }
    }

    private func fresh(_ observedAt: Date, now: Date) -> Bool {
        (-5...45).contains(now.timeIntervalSince(observedAt))
    }

    private mutating func trim() {
        if services.count > 64 {
            services = Dictionary(
                uniqueKeysWithValues: services.sorted {
                    $0.value.lastObservedAt > $1.value.lastObservedAt
                }.prefix(64).map { ($0.key, $0.value) }
            )
        }
        if approvals.count > 128 {
            approvals = Dictionary(
                uniqueKeysWithValues: approvals.sorted {
                    $0.value.lastObservedAt > $1.value.lastObservedAt
                }.prefix(128).map { ($0.key, $0.value) }
            )
        }
    }
}

public struct SparkAgentApprovalRoute: Identifiable, Equatable, Sendable {
    public let targetID: String
    public let projectID: String
    public let changeID: String
    public var id: String { "\(targetID).\(projectID).\(changeID)" }

    public init?(targetID: String, projectID: String, changeID: String) {
        guard UUID(uuidString: projectID) != nil, UUID(uuidString: changeID) != nil else {
            return nil
        }
        self.targetID = targetID
        self.projectID = projectID.lowercased()
        self.changeID = changeID.lowercased()
    }
}
