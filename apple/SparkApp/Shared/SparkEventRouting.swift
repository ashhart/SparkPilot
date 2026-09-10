import Foundation

/// The reads the app already performs, named so an event can ask for exactly the ones it changed.
struct SparkEventRefresh: OptionSet, Sendable, Hashable {
    let rawValue: Int

    /// Health, status and capabilities: what the Spark says about itself.
    static let status = SparkEventRefresh(rawValue: 1 << 0)
    /// The installed model inventory and each model's lifecycle state.
    static let models = SparkEventRefresh(rawValue: 1 << 1)
    /// The durable operations list the Activity surface reads.
    static let operations = SparkEventRefresh(rawValue: 1 << 2)
    /// Which model is serving requests right now.
    static let inference = SparkEventRefresh(rawValue: 1 << 3)
    /// Live telemetry: memory pressure, temperature, power.
    static let telemetry = SparkEventRefresh(rawValue: 1 << 4)
    /// The paired device list.
    static let devices = SparkEventRefresh(rawValue: 1 << 5)
    /// Guest and shared-access records.
    static let sharedAccess = SparkEventRefresh(rawValue: 1 << 6)
    /// Remote access state and its routes.
    static let remoteAccess = SparkEventRefresh(rawValue: 1 << 7)
    /// Saved automations and their runs.
    static let automations = SparkEventRefresh(rawValue: 1 << 8)
    /// The adopted workload inventory.
    static let workloads = SparkEventRefresh(rawValue: 1 << 9)

    /// What an event gap costs: the catalogue requires a full refresh after a reset.
    static let everything: SparkEventRefresh = [
        .status, .models, .operations, .inference, .telemetry,
        .devices, .sharedAccess, .remoteAccess, .automations, .workloads,
    ]
}

/// Maps `docs/EVENT_CATALOGUE.md` types to the refreshes they invalidate; unknown types do nothing.
enum SparkEventRouting {
    /// An unlisted type is ignored on purpose: the catalogue promises clients never break on one.
    static func refreshes(for type: String) -> SparkEventRefresh {
        table[type] ?? []
    }

    /// Every type this app acts on, for the contract test that keeps the list honest.
    static var routedTypes: [String] { table.keys.sorted() }

    private static let table: [String: SparkEventRefresh] = [
        "node.memory.pressure.changed": [.telemetry, .status],
        "node.temperature.warning": [.telemetry],

        "device.paired": [.devices],
        "device.revoked": [.devices],
        "shared_access.invitation.created": [.sharedAccess],
        "shared_access.updated": [.sharedAccess],
        "shared_access.revoked": [.sharedAccess],
        "guest.request.admitted": [.sharedAccess],
        "guest.request.refused": [.sharedAccess],
        "guest.route.refused": [.sharedAccess],

        "model.download.progress": [.operations, .models],
        "model.ready": [.models, .inference, .status],
        "model.draining": [.models, .inference],
        "model.unloaded": [.models, .inference],
        "model.failed": [.models, .inference],
        "model.load_failed": [.models, .inference],
        "model.unload_failed": [.models],
        "model.idle.unloaded": [.models, .inference],
        "model.idle.unload_failed": [.models],
        "model.memory.guard.armed": [.telemetry, .models],
        "model.memory.guard.triggered": [.telemetry, .models, .inference],
        "model.guard.stopped": [.models, .inference, .telemetry],
        "model.guard.stop_failed": [.models],
        "engine.draining": [.models, .inference],
        "workload.adopted": [.workloads],
        "workload.adoption_failed": [.workloads],

        "operation.created": [.operations],
        "operation.progress": [.operations],
        "operation.cancelled": [.operations, .status],
        "operation.completed": [.operations, .status],
        "operation.failed": [.operations, .status],

        "fabric.carrier_detected": [.status],
        "fabric.speed_changed": [.status],
        "fabric.ready": [.status],
        "fabric.degraded": [.status],
        "fabric.peer_authenticated": [.status],

        "cluster.node.joined": [.status],
        "cluster.node.left": [.status],
        "cluster.link.changed": [.status],
        "cluster.validation.progress": [.operations],
        "cluster.ready": [.status],
        "cluster.degraded": [.status],

        "build.worker.online": [.status],
        "build.worker.offline": [.status],
        "build.started": [.operations],
        "build.test.completed": [.operations],
        "build.artifact.ready": [.operations],
        "build.failed": [.operations],
        "build.completed": [.operations],
        "build.cancelled": [.operations],

        "automation.run.started": [.automations],
        "automation.run.completed": [.automations],
        "automation.run.failed": [.automations],

        "remote.tunnel.enabled": [.remoteAccess],
        "remote.tunnel.disabled": [.remoteAccess],
        "remote.tunnel.unhealthy": [.remoteAccess],
        "remote.route.hostname_changed": [.remoteAccess, .status],
        "remote.overlay.login_required": [.remoteAccess],
        "remote.overlay.rolled_back": [.remoteAccess],
        "remote.overlay.rollback_failed": [.remoteAccess],
    ]
}
