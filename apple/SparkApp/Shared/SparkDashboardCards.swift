import Foundation
import SparkAPI
import SparkCore
import SparkDesignSystem
import SparkLibrary
import SwiftUI

struct SparkDashboardTelemetryCard: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let title: String
    let value: String
    let detail: String
    let symbol: String
    var severity: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Image(systemName: symbol)
                    .foregroundStyle(
                        severity >= 3 ? Color.red : severity > 0 ? Color.orange : Color.accentColor
                    )
                    .accessibilityHidden(true)
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(
                    SparkStatTileLayout.detailLineLimit(
                        usesAccessibilityTextSize: dynamicTypeSize.isAccessibilitySize
                    )
                )
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(
            maxWidth: .infinity,
            minHeight: SparkStatTileLayout.minimumHeight(
                usesAccessibilityTextSize: dynamicTypeSize.isAccessibilitySize
            ),
            alignment: .leading
        )
        .padding(14)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(Text(.pair(value, detail)))

    }
}

/// Derive status colour from its semantic tone so localization cannot change severity.
struct SparkDashboardStatusRow: View {
    let title: String
    let value: SparkStatusValue
    let detail: String
    let symbol: String
    let help: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(Color.accentColor)
                .frame(width: 38, height: 38)
                .background(Color.accentColor.opacity(0.1), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).font(.headline)
                    SparkTooltipButton(title: title, message: help)
                }
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(value.text)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(value.tone == .attention ? Color.orange : Color.primary)
        }
        .padding()
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 14))

    }
}

struct SparkDashboardPage<Content: View>: View {
    let refresh: () async -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                content()
            }
            .frame(maxWidth: 760)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .refreshable { await refresh() }

    }
}
