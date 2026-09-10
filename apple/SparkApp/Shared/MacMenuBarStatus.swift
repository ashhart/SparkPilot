import Foundation
import SparkCore
import SparkLibrary

/// PLAN 41.3 gives the Mac a menu-bar status item; this is what it can say without a window.
struct MacMenuBarStatus: Equatable, Sendable {
    struct Spark: Equatable, Sendable, Identifiable {
        let id: String
        let name: String
        /// The connection state in words, never colour alone (§51.1).
        let state: String
        let symbol: String
        let detail: String?
        let isReachable: Bool
        let needsAttention: Bool
    }

    let sparks: [Spark]
    let summary: String
    /// The status item's own symbol, which changes only when a Spark needs the owner.
    let symbol: String

    var needsAttention: Bool { sparks.contains(where: \.needsAttention) }

    static func resolve(entries: [LibraryEntry]) -> MacMenuBarStatus {
        let sparks = entries.map(spark(for:))
        let reachable = sparks.count(where: \.isReachable)
        let summary: String =
            if sparks.isEmpty {
                String(localized: "No Sparks paired")
            } else {
                String(
                    localized: .macMenuBarReachable(
                        reachable: reachable.formatted(),
                        total: sparks.count.formatted()
                    )
                )
            }
        return MacMenuBarStatus(
            sparks: sparks,
            summary: summary,
            symbol: sparks.contains(where: \.needsAttention)
                ? "exclamationmark.triangle.fill" : "server.rack"
        )
    }

    private static func spark(for entry: LibraryEntry) -> Spark {
        let connection = LibraryConnectionPresentation.resolve(entry)
        let summary = LibraryCardSummary.resolve(entry: entry)
        let attention =
            entry.issue == .identityMismatch || entry.connectionState == .identityMismatch
            || entry.connectionState == .updateRequired
        return Spark(
            id: entry.id,
            name: entry.displayName,
            state: connection.label,
            symbol: connection.symbol,
            detail: connection.isOnline ? summary?.activeModel : summary?.lastContact,
            isReachable: connection.isOnline,
            needsAttention: attention
        )
    }
}
