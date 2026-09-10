import SparkDesignSystem
import SwiftUI

/// One Spark as Home shows it: who it is, how it is reached, what it is doing, one action, and how fresh that is.
struct FleetHomeCardView<Menu: View>: View {
    let card: FleetHomeSparkCard
    let onOpen: () -> Void
    /// Absent when this surface cannot launch a model, in which case no button is offered.
    let onModelAction: (() -> Void)?
    var onConfigureModel: (() -> Void)? = nil
    /// False when no route exists yet; the hint says so instead of the card looking broken.
    var canOpen = true
    var openHint = String(localized: "Opens this Spark")
    @ViewBuilder let menu: Menu

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            identityRow
            if !card.metrics.isEmpty { readings }
            actionRow
            Text(card.freshness)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    private var identityRow: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: onOpen) {
                HStack(alignment: .top, spacing: 12) {
                    artwork
                    VStack(alignment: .leading, spacing: 4) {
                        Text(card.name)
                            .font(.title3.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                        Label(card.connection.value, systemImage: card.connection.symbol)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let route = card.connection.detail {
                            Text(route)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canOpen)
            .accessibilityIdentifier("spark.fleet.open.\(card.entryID)")
            .accessibilityLabel(card.accessibilityLabel)
            .accessibilityHint(openHint)
            menu
        }
    }

    @ViewBuilder
    private var artwork: some View {
        if card.isCluster {
            SparkProductMark(size: 44)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "square.stack.3d.up.fill")
                        .font(.footnote)
                        .foregroundStyle(Color.accentColor)
                        .padding(3)
                        .background(.background, in: Circle())
                }
                .accessibilityHidden(true)
        } else {
            SparkProductMark(size: 44)
                .accessibilityHidden(true)
        }
    }

    private var readings: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 16) { readingItems }
            VStack(alignment: .leading, spacing: 12) { readingItems }
        }
    }

    private var readingItems: some View {
        ForEach(card.metrics) { metric in
            VStack(alignment: .leading, spacing: 4) {
                Text(metric.title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(metric.value)
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
                if let fraction = metric.fraction {
                    ProgressView(value: fraction)
                        .tint(metric.tone.color)
                        .frame(maxWidth: 140)
                }
                if let detail = metric.detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(metric.spokenLabel)
        }
    }

    @ViewBuilder
    private var actionRow: some View {
        switch card.action {
        case .loading(let line, let fraction):
            VStack(alignment: .leading, spacing: 8) {
                Label(line, systemImage: "hourglass")
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if let fraction {
                    ProgressView(value: fraction)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        case .launch:
            if let onModelAction {
                modelButton(onModelAction).buttonStyle(.borderedProminent)
                if let onConfigureModel {
                    Button("Change preset", action: onConfigureModel).buttonStyle(.bordered)
                }
            }
        case .switchModel:
            if let onModelAction {
                modelButton(onModelAction).buttonStyle(.bordered)
            }
        case .none:
            EmptyView()
        }
    }

    private func modelButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(card.action.title, systemImage: card.action.symbol)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 44)
        }
    }
}

extension FleetHomeCardView where Menu == EmptyView {
    init(
        card: FleetHomeSparkCard,
        onOpen: @escaping () -> Void,
        onModelAction: (() -> Void)? = nil
    ) {
        self.init(card: card, onOpen: onOpen, onModelAction: onModelAction) { EmptyView() }
    }
}
