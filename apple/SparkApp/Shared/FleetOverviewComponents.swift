import Foundation
import SparkCore
import SparkDesignSystem
import SparkWidgetSupport
import SwiftUI

/// Use the Spark dashboard tile shape for fleet summary statistics.
struct FleetStatTile: View {
    let title: String
    let value: String
    let detail: String
    let symbol: String
    let tone: FleetTone
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var isAccessibilitySize: Bool { dynamicTypeSize.isAccessibilitySize }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .foregroundStyle(tone == .neutral ? Color.accentColor : tone.color)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .lineLimit(
                    SparkStatTileLayout.scalesValueToFit(
                        usesAccessibilityTextSize: isAccessibilitySize
                    ) ? 1 : nil
                )
                .minimumScaleFactor(
                    SparkStatTileLayout.scalesValueToFit(
                        usesAccessibilityTextSize: isAccessibilitySize
                    ) ? 0.8 : 1
                )
                .fixedSize(horizontal: false, vertical: true)
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(
                    SparkStatTileLayout.detailLineLimit(
                        usesAccessibilityTextSize: isAccessibilitySize
                    )
                )
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(
            maxWidth: .infinity,
            minHeight: SparkStatTileLayout.minimumHeight(
                usesAccessibilityTextSize: isAccessibilitySize
            ),
            alignment: .leading
        )
        .padding(14)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(localized: .triple(title, value, detail)))
    }
}

/// Pair each full-width section card with its title, symbol and summary.
struct FleetOverviewCard<Content: View>: View {
    let kind: FleetCardKind
    let summary: String
    @ViewBuilder let content: Content
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Stack section title and summary when accessibility text no longer fits horizontally.
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 6) {
                    header
                    if !summary.isEmpty { summaryText }
                }
            } else {
                HStack(spacing: 10) {
                    header
                    Spacer()
                    if !summary.isEmpty { summaryText }
                }
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            summary.isEmpty ? kind.title : String(localized: .pair(kind.title, summary))
        )
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: kind.symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 30, height: 30)
                .background(Color.accentColor.opacity(0.1), in: Circle())
                .accessibilityHidden(true)
            Text(kind.title)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var summaryText: some View {
        Text(summary)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Chips that wrap onto as many lines as they need.
struct FleetChipRow<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        FlowLayout(spacing: 6) {
            content
        }
    }
}

struct FleetChip: View {
    let text: String
    var symbol: String? = nil
    let tint: Color

    var body: some View {
        HStack(spacing: 4) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.caption2)
                    .accessibilityHidden(true)
            }
            Text(text)
                .font(.caption.weight(.medium))
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .foregroundStyle(tint)
        .background(tint.opacity(0.12), in: Capsule())
    }
}

/// Wrap chips left to right when the next item exceeds available row width.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return CGSize(width: width == .infinity ? maxX : width, height: y + rowHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Presentation helpers

/// Pairs every temperature colour with a text label so health remains accessible without colour.
enum FleetHeat {
    static func word(_ celsius: Double) -> String {
        SparkThermalReading.word(SparkThermalReading.state(reported: nil, celsius: celsius))
    }

    static func color(_ celsius: Double) -> Color {
        tone(celsius).color
    }

    static func tone(_ celsius: Double) -> FleetTone {
        switch SparkThermalReading.state(reported: nil, celsius: celsius) {
        case .hot, .critical: .critical
        case .warm: .caution
        case .nominal, .unknown, .unavailable: .positive
        }
    }
}
