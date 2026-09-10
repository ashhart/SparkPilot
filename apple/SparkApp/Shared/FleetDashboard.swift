import Foundation
import SparkCore
import SparkDesignSystem
import SparkWidgetSupport
import SwiftUI

// MARK: - Customisation

/// Which cards are visible and in what order, persisted locally per device.
public struct FleetDashboardCustomization: Codable, Equatable, Sendable {
    public var order: [FleetCardKind]
    public var hiddenRawValues: Set<String>

    public init(
        order: [FleetCardKind] = FleetCardKind.allCases,
        hiddenRawValues: Set<String> = []
    ) {
        self.order = order
        self.hiddenRawValues = hiddenRawValues
    }

    /// Deduplicate saved card order while including newly introduced cards exactly once.
    public var visibleCards: [FleetCardKind] {
        var seen: Set<FleetCardKind> = []
        var visible: [FleetCardKind] = []
        for card in order where !hiddenRawValues.contains(card.rawValue) {
            if seen.insert(card).inserted {
                visible.append(card)
            }
        }
        for card in FleetCardKind.allCases where !seen.contains(card) {
            if !hiddenRawValues.contains(card.rawValue) {
                visible.append(card)
            }
        }
        return visible
    }

    public func isHidden(_ card: FleetCardKind) -> Bool {
        hiddenRawValues.contains(card.rawValue)
    }

    public mutating func setHidden(_ card: FleetCardKind, _ hidden: Bool) {
        if hidden {
            hiddenRawValues.insert(card.rawValue)
        } else {
            hiddenRawValues.remove(card.rawValue)
        }
    }
}

/// UserDefaults-backed persistence for the overview layout.
public struct FleetDashboardStore {
    public static let key = "spark.fleet.dashboard.cards.v1"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> FleetDashboardCustomization {
        guard
            let data = defaults.data(forKey: Self.key),
            let loaded = try? JSONDecoder().decode(FleetDashboardCustomization.self, from: data)
        else { return FleetDashboardCustomization() }
        return loaded
    }

    public func save(_ customization: FleetDashboardCustomization) {
        guard let data = try? JSONEncoder().encode(customization) else { return }
        defaults.set(data, forKey: Self.key)
    }
}

/// Owns persisted card layout; the Fleet surface derives its overview from the current library on every render.
@MainActor
@Observable
public final class FleetDashboardModel {
    public private(set) var overview: FleetOverviewSnapshot = .empty
    public private(set) var customization: FleetDashboardCustomization

    @ObservationIgnored
    private let store: FleetDashboardStore

    public init(store: FleetDashboardStore = FleetDashboardStore()) {
        self.store = store
        self.customization = store.load()
    }

    public func update(from snapshots: [TargetOperationalSnapshot], at date: Date = Date()) {
        overview = FleetOverviewBuilder.build(from: snapshots, at: date)
    }

    public func moveCard(_ card: FleetCardKind, offset: Int) {
        guard let index = customization.order.firstIndex(of: card) else { return }
        let target = index + offset
        guard customization.order.indices.contains(target) else { return }
        customization.order.swapAt(index, target)
        store.save(customization)
    }

    /// Drag reordering from a list.
    public func moveCards(fromOffsets source: IndexSet, toOffset destination: Int) {
        customization.order.move(fromOffsets: source, toOffset: destination)
        store.save(customization)
    }

    public func setCard(_ card: FleetCardKind, hidden: Bool) {
        customization.setHidden(card, hidden)
        store.save(customization)
    }

    public func resetLayout() {
        customization = FleetDashboardCustomization()
        store.save(customization)
    }
}

/// Show, hide and reorder every dashboard card without discarding saved choices.
struct FleetDashboardCustomizationView: View {
    @Bindable var model: FleetDashboardModel
    /// The complete card list stays available when a Spark has no reading yet.
    let cards: [FleetCardKind]
    @Environment(\.dismiss) private var dismiss

    private var order: [FleetCardKind] {
        model.customization.order.filter(cards.contains)
            + cards.filter { !model.customization.order.contains($0) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(order) { card in
                        Toggle(
                            isOn: Binding(
                                get: { !model.customization.isHidden(card) },
                                set: { model.setCard(card, hidden: !$0) }
                            )
                        ) {
                            Label(card.title, systemImage: card.symbol)
                        }
                        .accessibilityIdentifier("spark.dashboard.toggle.\(card.rawValue)")
                    }
                    .onMove { source, destination in
                        model.moveCards(fromOffsets: source, toOffset: destination)
                    }
                } footer: {
                    Text(
                        """
                        Drag to reorder. Turn a card off to remove it from Home. \
                        Your layout is saved on this device.
                        """
                    )
                }
                Section {
                    Button("Reset to Default Layout", role: .destructive) {
                        model.resetLayout()
                    }
                }
            }
            #if os(iOS)
                .environment(\.editMode, .constant(.active))
            #endif
            .navigationTitle("Customize Overview")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

/// Keep the customizable overview available for one Spark as well as a fleet.
struct FleetDashboardSection: View {
    let home: FleetHomePresentation
    let dashboard: FleetDashboardModel
    let onOpenSpark: (String) -> Void

    var body: some View {
        if home.showsAnyFleetSection {
            FleetOverviewView(home: home, dashboard: dashboard, onOpenSpark: onOpenSpark)
        }
    }
}
