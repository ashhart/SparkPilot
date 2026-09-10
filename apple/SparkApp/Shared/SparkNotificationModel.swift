import Foundation
import Observation
import SparkAPI
import SparkCore
import SparkLibrary
import SparkProjects
import SwiftUI
import UserNotifications

@MainActor
@Observable
public final class SparkNotificationModel {
    public private(set) var isEnabled: Bool
    public private(set) var authorization: SparkNotificationAuthorization = .unknown
    public private(set) var errorMessage: String?
    public private(set) var currentAlerts: [SparkLocalNotification] = []
    public private(set) var harnessUpdates: [SparkLocalNotification] = []
    private var harnessRefreshID = UUID()

    private let delivery: any SparkNotificationDelivering
    private let defaults: UserDefaults
    private let enabledKey: String
    private let stateKey: String
    private let backgroundScheduler: any SparkNotificationBackgroundScheduling
    private let remoteRegistrar: (any SparkRemoteNotificationRegistering)?
    private let remoteDeliveryEnabled: Bool
    private var observations: [String: SparkNotificationObservation]
    private var deliveredIdentifiers: [String]
    private var actionableCheckpoint: SparkActionableNotificationCheckpoint
    private var inferenceObservations: [String: SparkInferenceNotificationObservation] = [:]

    public init(
        delivery: any SparkNotificationDelivering = SystemSparkNotificationDelivery(),
        defaults: UserDefaults = .standard,
        enabledKey: String = "sparkpilot.notifications.enabled",
        stateKey: String = "sparkpilot.notifications.checkpoint.v2",
        backgroundScheduler: any SparkNotificationBackgroundScheduling =
            SystemSparkNotificationBackgroundScheduler(),
        remoteRegistrar: (any SparkRemoteNotificationRegistering)? = nil,
        remoteDeliveryEnabled: Bool = false
    ) {
        self.delivery = delivery
        self.defaults = defaults
        self.enabledKey = enabledKey
        self.stateKey = stateKey
        self.backgroundScheduler = backgroundScheduler
        self.remoteRegistrar = remoteRegistrar
        self.remoteDeliveryEnabled = remoteDeliveryEnabled
        self.isEnabled = defaults.bool(forKey: enabledKey)
        let checkpoint =
            defaults.data(forKey: stateKey).flatMap {
                try? JSONDecoder().decode(SparkNotificationCheckpoint.self, from: $0)
            } ?? .empty
        self.actionableCheckpoint = checkpoint.actionable ?? SparkActionableNotificationCheckpoint()
        self.observations = checkpoint.observations.mapValues(\.observation)
        self.deliveredIdentifiers = checkpoint.deliveredIdentifiers
    }

    public func prepare() async {
        await delivery.registerCategories()
        authorization = await delivery.authorization()
        if authorization == .denied, isEnabled {
            isEnabled = false
            defaults.set(false, forKey: enabledKey)
        }
        guard authorization == .allowed, isEnabled else {
            backgroundScheduler.cancel()
            return
        }
        backgroundScheduler.schedule()
        if remoteDeliveryEnabled, let remoteRegistrar {
            await remoteRegistrar.register()
        }
    }

    public func setEnabled(_ enabled: Bool) async {
        errorMessage = nil
        guard enabled else {
            isEnabled = false
            defaults.set(false, forKey: enabledKey)
            observations.removeAll()
            actionableCheckpoint = SparkActionableNotificationCheckpoint()
            deliveredIdentifiers.removeAll()
            defaults.removeObject(forKey: stateKey)
            backgroundScheduler.cancel()
            return
        }
        do {
            let granted: Bool
            if authorization == .allowed {
                granted = true
            } else {
                granted = try await delivery.requestAuthorization()
            }
            authorization = granted ? .allowed : .denied
            isEnabled = granted
            defaults.set(granted, forKey: enabledKey)
            if granted {
                backgroundScheduler.schedule()
                if remoteDeliveryEnabled, let remoteRegistrar {
                    await remoteRegistrar.register()
                }
            }
        } catch {
            isEnabled = false
            defaults.set(false, forKey: enabledKey)
            errorMessage = String(localized: "Notification permission could not be checked.")
        }
    }

    public func observe(_ entries: [LibraryEntry]) async {
        let current = Dictionary(
            uniqueKeysWithValues: entries.map { entry in
                let snapshot = entry.cachedOperationalSnapshot
                let notices = (snapshot?.warnings ?? []) + (snapshot?.blockers ?? [])
                var noticeCodes = Set(notices.map(\.code))
                if !entry.connectionState.isConnected || snapshot?.evidence.health.state != .current
                {
                    noticeCodes = noticeCodes.intersection([
                        "runtime.update_available", "runtime.update_required",
                        "target.identity_mismatch",
                    ])
                }
                switch snapshot?.runtime.updateState {
                case .available:
                    noticeCodes.insert("runtime.update_available")
                case .required:
                    noticeCodes.insert("runtime.update_required")
                case .current, .unknown, nil:
                    break
                }
                let hasCurrentOperations =
                    entry.connectionState.isConnected
                    && snapshot?.evidence.operations.state == .current
                let operations =
                    hasCurrentOperations
                    ? snapshot?.operations ?? []
                    : observations[entry.id]?.operations ?? []
                return (
                    entry.id,
                    SparkNotificationObservation(
                        targetID: entry.id,
                        connectionState: entry.connectionState,
                        operations: operations,
                        noticeCodes: noticeCodes,
                        observedAt: hasCurrentOperations
                            ? snapshot?.evaluatedAt : observations[entry.id]?.observedAt
                    )
                )
            }
        )
        let previous = observations
        observations = current
        currentAlerts = SparkNotificationPlanner.notifications(previous: [:], current: current)
        harnessUpdates.removeAll { update in
            !entries.contains {
                $0.id == update.targetID && $0.issue == nil && $0.connectionState.isConnected
            }
        }
        actionableCheckpoint.retainTargets(Set(entries.filter { $0.issue == nil }.map(\.id)))
        for entry in entries where !entry.connectionState.isConnected {
            actionableCheckpoint.suspendServiceHealth(targetID: entry.id)
        }
        guard isEnabled, authorization == .allowed else {
            persistCheckpoint()
            return
        }
        let delivered = Set(deliveredIdentifiers)
        for notification in SparkNotificationPlanner.notifications(
            previous: previous,
            current: current
        ).filter({ !delivered.contains($0.identifier) }) {
            do {
                try await delivery.deliver(notification)
                recordDelivered(notification.identifier)
            } catch {
                errorMessage = String(localized: "A notification could not be delivered.")
            }
        }
        await deliverActionable([])
        persistCheckpoint()
        backgroundScheduler.schedule()
    }

    public func refreshHarnessUpdates(provider: any ProjectDataProviding) async {
        let refreshID = UUID()
        harnessRefreshID = refreshID
        var updates: [SparkLocalNotification] = []
        for target in await provider.targets() where target.projectsAvailable {
            guard !Task.isCancelled, harnessRefreshID == refreshID else { return }
            guard let collection = try? await provider.projects(targetID: target.id) else {
                continue
            }
            updates += Self.harnessUpdateNotices(targetID: target.id, projects: collection.items)
        }
        guard !Task.isCancelled, harnessRefreshID == refreshID else { return }
        harnessUpdates = updates.filter {
            observations[$0.targetID]?.connectionState.isConnected == true
        }.sorted { $0.identifier < $1.identifier }
    }

    static func harnessUpdateNotices(
        targetID: String,
        projects: [GeneratedAPI.Project]
    ) -> [SparkLocalNotification] {
        var identifiers = Set<String>()
        return projects.flatMap { $0.harnessUpdates ?? [] }.compactMap { update in
            let name: String =
                switch update.harness {
                case .ohMyPi: String(localized: "Oh My Pi")
                case .openCode: String(localized: "OpenCode")
                case .pi: String(localized: "Pi")
                case .claudeCode: String(localized: "Claude Code")
                case .codex: String(localized: "Codex")
                }
            let identifier =
                [targetID, "harness", update.harness.rawValue, update.availableVersion].joined(
                    separator: "."
                )
            guard update.installedVersion != update.availableVersion,
                identifiers.insert(identifier).inserted
            else { return nil }
            return SparkLocalNotification(
                identifier: identifier,
                title: String(localized: .harnessUpdateTitle(name)),
                body: String(localized: .harnessUpdateBody(update.availableVersion)),
                category: "SPARK_HEALTH",
                targetID: targetID
            )
        }
    }

    public func observeInference(_ observation: SparkInferenceNotificationObservation) async {
        let previous = inferenceObservations[observation.targetID]
        inferenceObservations[observation.targetID] = observation
        guard isEnabled, authorization == .allowed else { return }
        for notification in SparkInferenceNotificationPlanner.notifications(
            from: previous,
            to: observation
        ) {
            do {
                try await delivery.deliver(notification)
            } catch {
                errorMessage = String(localized: "A notification could not be delivered.")
            }
        }
    }

    var approvalWatches: [(targetID: String, projectID: String)] {
        actionableCheckpoint.approvals.keys.sorted().compactMap { key in
            guard let separator = key.lastIndex(of: ".") else { return nil }
            let projectID = String(key[key.index(after: separator)...])
            guard UUID(uuidString: projectID) != nil else { return nil }
            return (String(key[..<separator]), projectID)
        }
    }

    var managedServiceWatches: [String] {
        actionableCheckpoint.services.keys.sorted().filter { $0.hasSuffix(".open-webui") }
            .map { String($0.dropLast(".open-webui".count)) }
    }

    public func observeManagedService(_ observation: SparkManagedServiceObservation) async {
        let planned = actionableCheckpoint.observeService(observation, now: Date())
        await deliverActionable(planned)
    }

    public func observeAgentApprovals(_ observation: SparkAgentApprovalObservation) async {
        let planned = actionableCheckpoint.observeApprovals(observation, now: Date())
        await deliverActionable(planned)
    }

    private func deliverActionable(_ notifications: [SparkLocalNotification]) async {
        defer { persistCheckpoint() }
        guard isEnabled, authorization == .allowed else { return }
        for notification in notifications
        where !deliveredIdentifiers.contains(notification.identifier)
            && !actionableCheckpoint.pending.contains(where: {
                $0.identifier == notification.identifier
            })
        {
            actionableCheckpoint.pending.append(notification)
        }
        actionableCheckpoint.pending = Array(actionableCheckpoint.pending.suffix(128))
        // Save content-free notification state before delivery and reuse its system identifier for idempotent retries.
        persistCheckpoint()
        for notification in actionableCheckpoint.pending {
            do {
                try await delivery.deliver(notification)
                recordDelivered(notification.identifier)
                actionableCheckpoint.pending.removeAll { $0.identifier == notification.identifier }
            } catch {
                errorMessage = String(localized: "A notification could not be delivered.")
            }
        }
    }

    public func scheduleNextBackgroundRefresh() {
        guard isEnabled, authorization == .allowed else { return }
        backgroundScheduler.schedule()
    }

    private func recordDelivered(_ identifier: String) {
        deliveredIdentifiers.removeAll(where: { $0 == identifier })
        deliveredIdentifiers.append(identifier)
        if deliveredIdentifiers.count > 512 {
            deliveredIdentifiers.removeFirst(deliveredIdentifiers.count - 512)
        }
    }

    private func persistCheckpoint() {
        let checkpoint = SparkNotificationCheckpoint(
            observations: observations.mapValues(SparkNotificationCheckpointObservation.init),
            deliveredIdentifiers: deliveredIdentifiers,
            actionable: actionableCheckpoint
        )
        if let data = try? JSONEncoder().encode(checkpoint) {
            defaults.set(data, forKey: stateKey)
        }
    }
}
