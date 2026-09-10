import Foundation
import SparkDiscovery

/// PLAN 10.2.3 groups what discovery found; one flat list hides which of the three a row is.
struct AddSparkResultGroups: Equatable, Sendable {
    /// Runtime nodes that belong to no cluster: a single Spark to pair with.
    let runtime: [DiscoveredSpark]
    /// Runtime nodes advertising a cluster, shown as the cluster they claim.
    let clusters: [DiscoveredSpark]
    /// Machines answering on SSH with no runtime advertisement of their own (10.2.2).
    let dgx: [BootstrapSpark]

    /// Name hints only: SSH discovery cannot prove the hardware type.
    var possibleSparks: [BootstrapSpark] { dgx.filter { Self.hasSparkName($0.displayName) } }
    var otherDevices: [BootstrapSpark] { dgx.filter { !Self.hasSparkName($0.displayName) } }

    static func hasSparkName(_ name: String) -> Bool {
        normalised(name).split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .contains { ["spark", "dgx", "gb10"].contains(String($0)) }
    }

    var isEmpty: Bool { runtime.isEmpty && clusters.isEmpty && dgx.isEmpty }

    static func resolve(
        nodes: [DiscoveredSpark],
        bootstrap: [BootstrapSpark]
    ) -> AddSparkResultGroups {
        let known = Set(nodes.map { normalised($0.displayName) })
        return AddSparkResultGroups(
            runtime: nodes.filter { ($0.clusterID ?? "").isEmpty },
            clusters: nodes.filter { !($0.clusterID ?? "").isEmpty },
            // A Spark already running the runtime is not also offered as a machine to install on.
            dgx: bootstrap.filter { !known.contains(normalised($0.displayName)) }
        )
    }

    /// Bonjour instance names and SSH machine names differ by case and a trailing .local.
    private static func normalised(_ name: String) -> String {
        var value = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasSuffix(" ssh") { value.removeLast(4) }
        while value.hasSuffix(".") { value.removeLast() }
        if value.hasSuffix(".local") { value.removeLast(".local".count) }
        return value
    }
}
