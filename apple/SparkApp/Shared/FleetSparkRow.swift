import SwiftUI

/// Open a Spark from any overview card without hiding its name or reading at large text sizes.
struct FleetSparkRow<Trailing: View>: View {
    let spark: FleetSparkSummary
    let value: String
    let onOpen: (String) -> Void
    @ViewBuilder let trailing: Trailing
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Button {
            onOpen(spark.entryID)
        } label: {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 8) {
                        identity
                        HStack {
                            trailing
                            Spacer(minLength: 0)
                            chevron
                        }
                    }
                } else {
                    HStack(spacing: 12) {
                        identity.frame(maxWidth: .infinity, alignment: .leading)
                        trailing.frame(maxWidth: .infinity, alignment: .trailing)
                        chevron
                    }
                }
            }
            .padding(.vertical, 6)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            String(
                localized: .triple(
                    spark.displayName,
                    spark.connectionPath?.spokenSummary ?? spark.connectionLabel,
                    value
                )
            )
        )
        .accessibilityHint("Opens this Spark")
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(spark.displayName).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Label(spark.connectionLabel, systemImage: spark.connectionSymbol)
                .font(.caption).foregroundStyle(spark.connectionTone.color)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var chevron: some View {
        Image(systemName: "chevron.forward").font(.caption.weight(.semibold))
            .foregroundStyle(.tertiary).accessibilityHidden(true)
    }
}
