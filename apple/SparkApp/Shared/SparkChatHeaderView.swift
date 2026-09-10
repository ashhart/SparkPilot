import Foundation
import SparkDesignSystem
import SwiftUI

/// The chat header: which Spark and model are answering, and how much of the window this chat is using.
@MainActor
struct SparkChatHeaderView: View {
    let model: SparkChatModel
    let selectTarget: (SparkChatTarget) -> Void

    private var groups: [SparkChatTargetMenu.Group] {
        SparkChatTargetMenu.groups(
            choices: model.availableModelChoices,
            catalogue: model.catalogue,
            selectedID: model.selectedTarget?.selectionID
        )
    }

    var body: some View {
        Menu {
            if let use = model.contextUse, use.tone != .normal || use.isTruncated {
                Section(use.accessibilityValue) {
                    Button("New chat", systemImage: "square.and.pencil") {
                        model.newConversation()
                    }
                }
            }
            ForEach(groups) { group in
                Section(group.displayName) {
                    ForEach(group.items) { item in
                        Button {
                            selectTarget(item.target)
                        } label: {
                            Label(item.title, systemImage: item.symbol)
                        }
                    }
                }
            }
            ForEach(SparkChatTargetMenu.unavailable(model.catalogue)) { item in
                Label(item.title, systemImage: item.symbol)
            }
        } label: {
            label
        }
        .tint(.primary)
        .accessibilityLabel(SparkChatAccessibility.targetPickerLabel)
        .accessibilityValue(accessibilityValue)
    }

    private var label: some View {
        VStack(spacing: 2) {
            HStack(spacing: 5) {
                Text(model.selectedTarget?.modelName ?? String(localized: "Chat"))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            if let subtitle {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let use = model.contextUse, let fraction = use.fraction {
                SparkChatUsageBar(fraction: fraction, tone: use.tone)
            }
        }
        .frame(maxWidth: 260, minHeight: 44)
        .contentShape(Rectangle())
    }

    /// 52.1: the header names where the answer runs, with the context reading beside it.
    private var subtitle: String? {
        let spark = model.selectedTarget?.executionLocation.label
        guard let summary = model.contextUse?.summary else { return spark }
        guard let spark else { return summary }
        return String(localized: .joined(spark, summary))
    }

    private var accessibilityValue: String {
        let execution = model.selectedTarget?.executionAccessibilityLabel
        guard let use = model.contextUse else { return execution ?? "" }
        guard let execution else { return use.accessibilityValue }
        return String(localized: .pair(execution, use.accessibilityValue))
    }
}

/// A thin bar under the header, coloured by how crowded the window is.
struct SparkChatUsageBar: View {
    let fraction: Double
    let tone: SparkChatUsageTone

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(ChatStyle.border)
                Capsule()
                    .fill(SparkChatUsageBar.colour(for: tone))
                    .frame(width: max(2, geometry.size.width * fraction))
            }
        }
        .frame(height: 3)
        .frame(maxWidth: 180)
        .accessibilityHidden(true)
    }

    static func colour(for tone: SparkChatUsageTone) -> Color {
        switch tone {
        case .normal: Color.secondary
        case .caution: Color.orange
        case .critical: Color.red
        }
    }
}
