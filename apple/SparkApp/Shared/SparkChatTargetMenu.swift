import Foundation

/// Group chat targets by Spark so a fleet's models read as one list per machine, each with its state.
enum SparkChatTargetMenu {
    enum State: Equatable {
        case selected, running, installed

        var symbol: String {
            switch self {
            case .selected: "checkmark.circle.fill"
            case .running: "play.circle"
            case .installed: "arrow.down.circle"
            }
        }
    }

    struct Item: Identifiable, Equatable {
        let target: SparkChatTarget
        let state: State
        var id: String { target.selectionID }
        var title: String { target.modelName }
        var symbol: String { state.symbol }
    }

    struct Group: Identifiable, Equatable {
        let id: String
        let displayName: String
        let items: [Item]
    }

    struct Unavailable: Identifiable, Equatable {
        let id: String
        let title: String
        let symbol: String
    }

    static func groups(
        choices: [SparkChatTarget],
        catalogue: SparkChatTargetCatalogue,
        selectedID: String?
    ) -> [Group] {
        let running = Set(catalogue.targets.map(\.selectionID))
        var order: [String] = []
        var names: [String: String] = [:]
        var items: [String: [Item]] = [:]
        for target in choices {
            let state: State =
                target.selectionID == selectedID
                ? .selected : running.contains(target.selectionID) ? .running : .installed
            if names[target.id] == nil {
                order.append(target.id)
                names[target.id] = target.displayName
            }
            items[target.id, default: []].append(Item(target: target, state: state))
        }
        return order.map { Group(id: $0, displayName: names[$0] ?? $0, items: items[$0] ?? []) }
    }

    static func unavailable(_ catalogue: SparkChatTargetCatalogue) -> [Unavailable] {
        catalogue.unavailableTargets.enumerated().map { index, target in
            Unavailable(
                id: (target.id ?? target.name) + "#\(index)",
                title: String(localized: .pair(target.name, target.reason.title)),
                symbol: target.reason.symbol
            )
        }
    }
}
