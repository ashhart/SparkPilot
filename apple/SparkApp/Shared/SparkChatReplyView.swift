import SwiftUI

/// A compact quote shared by the composer and sent messages; activation returns to its source.
struct SparkChatReplyView: View {
    let reply: SparkChatReplyReference
    let sourceAvailable: Bool
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(.tint)
                    .frame(width: 3)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Label(
                        reply.role == .user
                            ? String(localized: "Replying to you")
                            : String(localized: "Replying to Spark"),
                        systemImage: "arrowshape.turn.up.left"
                    )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tint)
                    Text(verbatim: reply.preview)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(12)
            .fixedSize(horizontal: false, vertical: true)
            .frame(minHeight: 44)
            .background(ChatStyle.surface, in: RoundedRectangle(cornerRadius: 14))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .disabled(!sourceAvailable)
        .accessibilityLabel(reply.role == .user ? "Replying to you" : "Replying to Spark")
        .accessibilityValue(Text(verbatim: reply.preview))
        .accessibilityHint(
            sourceAvailable ? "Show original message" : "Original message unavailable"
        )
    }
}
