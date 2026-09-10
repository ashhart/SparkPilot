import Foundation
import SparkCore
import SparkDesignSystem
import SparkWidgetSupport
import SwiftUI

// MARK: - Views

/// The customizable Home overview, shared by iPhone, iPad and Mac.
struct FleetOverviewView: View {
    private let home: FleetHomePresentation
    @Bindable private var dashboard: FleetDashboardModel
    private let onOpenSpark: (String) -> Void
    @State private var isCustomizing = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(
        home: FleetHomePresentation,
        dashboard: FleetDashboardModel,
        onOpenSpark: @escaping (String) -> Void
    ) {
        self.home = home
        self.dashboard = dashboard
        self.onOpenSpark = onOpenSpark
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if !home.rollUp.isEmpty { statStrip }
            ForEach(home.fleetCards) { card in
                cardView(card)
            }
        }
        .sheet(isPresented: $isCustomizing) {
            FleetDashboardCustomizationView(model: dashboard, cards: home.customisableCards)
        }
    }

    @ViewBuilder
    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Fleet Overview")
                .font(.title2.bold())
            Spacer()
            if !home.customisableCards.isEmpty {
                Button {
                    isCustomizing = true
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                        .accessibilityHidden(true)
                }
                .accessibilityLabel("Customize Cards")
                .accessibilityIdentifier("spark.dashboard.options")
            }
        }
    }

    // MARK: Roll-up

    private var statStrip: some View {
        LazyVGrid(
            columns: SparkStatTileLayout.columns(
                usesAccessibilityTextSize: dynamicTypeSize.isAccessibilitySize
            ),
            alignment: .leading,
            spacing: 12
        ) {
            ForEach(home.rollUp) { metric in
                FleetStatTile(
                    title: metric.title,
                    value: metric.value,
                    detail: metric.detail ?? "",
                    symbol: metric.symbol,
                    tone: metric.tone
                )
            }
        }
    }

    private func cardView(_ card: FleetCardKind) -> some View {
        FleetDashboardDetailCard(kind: card, overview: home.overview, onOpenSpark: onOpenSpark)
            .accessibilityIdentifier("spark.dashboard.card.\(card.rawValue)")
    }
}
