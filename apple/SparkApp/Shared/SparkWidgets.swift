import Foundation
import Observation
import SparkAPI
import SparkCore
import SparkLibrary
import SparkWidgetSupport
import SwiftUI
import WidgetKit
#if os(iOS)
    import BackgroundTasks
#endif

@MainActor
public enum SparkWidgetBackgroundRefresh {
    public static let identifier = "com.sparkfabric.widgets.refresh"

    static func schedule(library: SparkLibrary) async {
        #if os(iOS)
            guard !library.entries.isEmpty else {
                BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
                return
            }
            // Keep an earlier request instead of postponing it whenever the app is opened.
            let pending = await BGTaskScheduler.shared.pendingTaskRequests()
            guard !pending.contains(where: { $0.identifier == identifier }) else { return }
            let request = BGAppRefreshTaskRequest(identifier: identifier)
            request.earliestBeginDate = Date(
                timeIntervalSinceNow: SparkWidgetFreshness.refreshInterval
            )
            try? BGTaskScheduler.shared.submit(request)
        #endif
    }

    static func run(library: SparkLibrary) async {
        // Reserve the next opportunity before iOS can expire this network refresh.
        await schedule(library: library)
        let lock = AppLockModel()
        let publisher = SparkWidgetPublisher()
        if !lock.isEnabled {
            await SignedCrossTargetModelLibraryProvider(library: library).refreshChatEvidence()
            await publisher.refreshMembers(library: library, appLock: lock)
        }
        publisher.publish(library: library, appLock: lock, forceReload: true)
    }
}

@MainActor @Observable
public final class SparkWidgetNavigation {
    public static let shared = SparkWidgetNavigation()
    public var targetID: String?
    /// A pairing invitation opened from Camera, Messages or AirDrop, held until the pairing screen takes it.
    public private(set) var pendingPairingPayload: String?

    public func open(_ url: URL) {
        if let payload = Self.pairingPayload(from: url) {
            pendingPairingPayload = payload
            return
        }
        targetID = SparkWidgetSnapshot.targetID(from: url)
    }

    /// Accept sparkpilot:// and legacy spark:// invitations case-insensitively.
    public static func pairingPayload(from url: URL) -> String? {
        let text = url.absoluteString
        let accepted = [
            "sparkpilot://pair/", "sparkpilot://pair-batch/",
            "spark://pair/", "spark://pair-batch/",
        ]
        guard ["sparkpilot", "spark"].contains(url.scheme?.lowercased() ?? ""),
            accepted.contains(where: text.lowercased().hasPrefix)
        else { return nil }
        return text
    }

    /// Send the owner to the library; "all" is the widget's existing home route.
    public func requestHome() {
        targetID = "all"
    }

    /// Open one Spark's dashboard on a named section; the dashboard takes the section when it appears.
    public func openDashboard(targetID id: String, section: String) {
        pendingDashboardSection = section
        targetID = id
    }

    public private(set) var pendingDashboardSection: String?

    public func takePendingDashboardSection() -> String? {
        defer { pendingDashboardSection = nil }
        return pendingDashboardSection
    }

    public func takePendingPairingPayload() -> String? {
        defer { pendingPairingPayload = nil }
        return pendingPairingPayload
    }
}

/// Deliver widget navigation requests to a root through a typed closure, keeping the root's modifier chain short.
public struct SparkNavigationRequestObserver: ViewModifier {
    private let openTarget: (String) -> Void

    public init(openTarget: @escaping (String) -> Void) {
        self.openTarget = openTarget
    }

    public func body(content: Content) -> some View {
        content.onChange(of: SparkWidgetNavigation.shared.targetID, initial: true) { _, targetID in
            guard let targetID else { return }
            openTarget(targetID)
            SparkWidgetNavigation.shared.targetID = nil
        }
    }
}

/// One Spark's connection line for the widget: what it says and whether it counts as connected.
struct SparkWidgetConnectionLine: Equatable, Sendable {
    let label: String
    let isConnected: Bool
}

@MainActor
enum SparkWidgetSnapshotBuilder {
    /// A Spark that answered is connected; only one that did not is drawn as offline.
    static func connectionLine(
        reachable: Bool,
        kind: SparkTransportKind?
    ) -> SparkWidgetConnectionLine {
        let state: TargetConnectionState
        switch kind {
        case .directEthernet: state = .connectedDirect
        case .localWiFi: state = .connectedWiFi
        case .privateOverlay: state = .connectedRemote
        case nil:
            guard reachable else {
                return line(.offlineCached, isConnected: false)
            }
            // Reachable with no recorded route: connected, without naming a path it cannot name.
            return SparkWidgetConnectionLine(
                label: String(localized: "Connected"),
                isConnected: true
            )
        }
        return line(state, isConnected: state.isConnectedTarget)
    }

    private static func line(
        _ state: TargetConnectionState,
        isConnected: Bool
    ) -> SparkWidgetConnectionLine {
        SparkWidgetConnectionLine(
            label: FleetPresentationBuilder.connectionPresentation(
                state: state,
                isChecking: false
            ).label,
            isConnected: isConnected
        )
    }

    static func make(
        library: SparkLibrary,
        readings: [String: SparkWidgetNode],
        isPrivate: Bool,
        at date: Date
    ) -> SparkWidgetSnapshot {
        guard !isPrivate else { return SparkWidgetSnapshot(isPrivate: true) }
        let targets = library.entries.compactMap { entry -> SparkWidgetTarget? in
            guard entry.issue != .identityMismatch,
                let snapshot = library.operationalSnapshot(for: entry.id, at: date)
            else { return nil }
            let nodes = entry.members.map { member -> SparkWidgetNode in
                let id = member.nodeID.rawValue.uuidString.lowercased()
                let cached = readings[id]
                if member.nodeID == entry.coordinatorNodeID,
                    let memory = snapshot.unifiedMemory,
                    let observed = snapshot.evidence.memory.observedAt,
                    observed >= (cached?.observedAt ?? .distantPast)
                {
                    return SparkWidgetNode(
                        id: id,
                        name: member.name,
                        totalBytes: memory.totalBytes,
                        availableBytes: memory.availableBytes,
                        observedAt: observed
                    )
                }
                return cached ?? SparkWidgetNode(id: id, name: member.name)
            }
            // Retain widget reachability until its own expiry while clearing it immediately on a failed authenticated probe.
            let reachable =
                entry.issue == nil
                && entry.members.contains {
                    $0.nodeID == entry.coordinatorNodeID && $0.reachable
                }
            let connection = connectionLine(
                reachable: reachable,
                kind: reachable ? entry.preferredRoute?.kind : nil
            )
            let inference =
                snapshot.activeInference.map {
                    FleetPresentationBuilder.inferenceStateLabel($0.state)
                } ?? String(localized: "Unknown")
            let active = snapshot.activeInference
            let modelName: String? =
                if let active, [.ready, .idle, .draining].contains(active.state),
                    let identity = active.modelIdentity
                {
                    snapshot.placements.first(where: { $0.identity == identity })?.displayName
                } else {
                    nil
                }
            return SparkWidgetTarget(
                id: entry.id,
                name: entry.displayName,
                isCluster: entry.kind == .cluster,
                nodes: nodes,
                connection: connection.label,
                isConnected: connection.isConnected,
                observedAt: snapshot.lastSuccessfulContact,
                inference: inference,
                inferenceObservedAt: snapshot.evidence.inference.observedAt,
                temperature: snapshot.temperatureCelsius,
                activeModelName: modelName
            )
        }
        return SparkWidgetSnapshot(targets: targets)
    }
}

/// Keep signed pinned network reads in the unlocked host app; widgets read only App Group display snapshots.
@MainActor @Observable
final class SparkWidgetPublisher {
    private var readings: [String: SparkWidgetNode] = [:]
    private var lastReload = Date.distantPast
    private var lastTargetIDs: Set<String> = []
    private var wasPrivate = false

    func publish(library: SparkLibrary, appLock: AppLockModel, forceReload: Bool = false) {
        // A background refresh may overlap a foreground change to the lock preference.
        let isPrivate =
            appLock.isEnabled || UserDefaults.standard.bool(forKey: AppLockModel.enabledKey)
        if isPrivate { readings.removeAll() }
        let snapshot = SparkWidgetSnapshotBuilder.make(
            library: library,
            readings: readings,
            isPrivate: isPrivate,
            at: Date()
        )
        let ids = Set(snapshot.targets.map(\.id))
        let privacyChanged = wasPrivate != snapshot.isPrivate || ids != lastTargetIDs
        do {
            let changed = try SparkWidgetStore.write(snapshot)
            if (changed || forceReload)
                && (privacyChanged || forceReload || Date().timeIntervalSince(lastReload) >= 60)
            {
                for kind in SparkWidgetStore.kinds {
                    WidgetCenter.shared.reloadTimelines(ofKind: kind)
                }
                lastReload = Date()
            }
            wasPrivate = snapshot.isPrivate
            lastTargetIDs = ids
        } catch {
            // Widgets remain on their last timestamped reading; no credential or network fallback.
        }
    }

    func refreshMembers(library: SparkLibrary, appLock: AppLockModel) async {
        guard !appLock.isEnabled else { return }
        let entries = library.entries
        let allowed = Set(
            entries.flatMap { $0.members.map { $0.nodeID.rawValue.uuidString.lowercased() } }
        )
        readings = readings.filter { allowed.contains($0.key) }
        var seen = Set<String>()
        for entry in entries where entry.issue == nil && entry.kind == .cluster {
            for member in entry.members {
                guard !Task.isCancelled, !appLock.isEnabled else { return }
                let id = member.nodeID.rawValue.uuidString.lowercased()
                guard seen.insert(id).inserted,
                    let trust = StoredNodeTrust.reader(id),
                    let route = member.routes.sorted(by: {
                        ($0.lastSuccess ?? .distantPast) > ($1.lastSuccess ?? .distantPast)
                    }).first?.baseURL
                else { continue }
                do {
                    let signer = try DeviceIdentityStore.loadOrCreateSigner(
                        nodeID: member.nodeID.rawValue
                    )
                    let api = try SparkAPIClient.pinned(to: trust.tlsFingerprint, signer: signer)
                    let identity = try await api.identity(route: route)
                    guard identity.nodeID == member.nodeID, identity.clusterID == entry.clusterID,
                        identity.authorityFingerprint == trust.authorityFingerprint
                    else {
                        readings[id] = nil
                        continue
                    }
                    let status = try await api.status(route: route)
                    guard status.identity.nodeID == member.nodeID,
                        status.identity.clusterID == entry.clusterID,
                        status.identity.authorityFingerprint == trust.authorityFingerprint
                    else {
                        readings[id] = nil
                        continue
                    }
                    guard
                        library.entry(id: entry.id)?.members.contains(where: {
                            $0.nodeID == member.nodeID
                        }) == true
                    else { continue }
                    readings[id] = SparkWidgetNode(
                        id: id,
                        name: member.name,
                        totalBytes: status.system.unifiedMemoryTotalBytes,
                        availableBytes: status.system.unifiedMemoryAvailableBytes,
                        observedAt: Date()
                    )
                } catch { /* Keep the preceding timestamp, never manufacture a fresh reading. */  }
            }
        }
        publish(library: library, appLock: appLock, forceReload: true)
    }
}

private struct SparkWidgetsModifier: ViewModifier {
    let library: SparkLibrary
    let appLock: AppLockModel
    @State private var publisher = SparkWidgetPublisher()
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .onChange(of: library.entries, initial: true) { _, _ in
                publisher.publish(library: library, appLock: appLock)
            }
            .onChange(of: library.entries.map(\.id), initial: true) { _, _ in
                Task { await SparkWidgetBackgroundRefresh.schedule(library: library) }
            }
            .onChange(of: appLock.isEnabled) { _, _ in
                publisher.publish(library: library, appLock: appLock, forceReload: true)
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active {
                    // Flush coalesced readings before iOS suspends the foreground sweep.
                    publisher.publish(library: library, appLock: appLock, forceReload: true)
                    Task { await SparkWidgetBackgroundRefresh.schedule(library: library) }
                }
            }
            .task(id: scenePhase) {
                #if os(iOS)
                    guard scenePhase == .active else { return }
                #endif
                await SparkWidgetBackgroundRefresh.schedule(library: library)
                let provider = SignedCrossTargetModelLibraryProvider(library: library)
                while !Task.isCancelled {
                    if !appLock.isEnabled {
                        await provider.refreshChatEvidence()
                        await publisher.refreshMembers(library: library, appLock: appLock)
                    }
                    do { try await Task.sleep(for: .seconds(60)) } catch { return }
                }
            }
    }
}

extension View {
    public func sparkWidgets(library: SparkLibrary, appLock: AppLockModel) -> some View {
        modifier(SparkWidgetsModifier(library: library, appLock: appLock))
    }
}
