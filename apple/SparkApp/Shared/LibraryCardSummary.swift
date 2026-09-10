import Foundation
import SparkCore
import SparkLibrary

/// The compact iPhone card's facts, so adapt Stage 2's five fields do not stay on iPad and Mac only.
struct LibraryCardSummary: Equatable, Sendable {
    let lastContact: String
    let availableMemory: String
    let activeModel: String
    let installedModels: String
    let nextAction: NextAction

    /// The one action a card offers, named for what it does to this Spark.
    enum NextAction: Equatable, Sendable {
        case open
        case checkAgain
        case reviewRecovery
        case update

        var title: String {
            switch self {
            case .open: String(localized: "Open")
            case .checkAgain: String(localized: "Check Again")
            case .reviewRecovery: String(localized: "Review Recovery")
            case .update: String(localized: "Update")
            }
        }
    }

    /// Read the same builders the iPad and Mac card uses, so the two surfaces cannot drift apart.
    static func resolve(entry: LibraryEntry) -> LibraryCardSummary? {
        guard let snapshot = entry.cachedOperationalSnapshot else { return nil }
        return LibraryCardSummary(
            lastContact: FleetPresentationBuilder.lastContact(snapshot),
            availableMemory: FleetPresentationBuilder.availableMemory(snapshot),
            activeModel: FleetPresentationBuilder.activeModel(snapshot),
            installedModels: FleetPresentationBuilder.installedModels(snapshot),
            nextAction: action(for: entry)
        )
    }

    static func action(for entry: LibraryEntry) -> NextAction {
        if entry.issue == .identityMismatch { return .reviewRecovery }
        switch entry.connectionState {
        case .identityMismatch: return .reviewRecovery
        case .updateRequired: return .update
        case .offlineCached: return .checkAgain
        default: return .open
        }
    }
}
