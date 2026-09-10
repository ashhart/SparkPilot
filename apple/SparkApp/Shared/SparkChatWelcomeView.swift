import SwiftUI

/// QA-10: how much of the welcome is drawn at a given text size, so the block still fits the transcript when the type is large.
struct SparkChatWelcomeLayout: Equatable, Sendable {
    let showsSupportingLine: Bool
    let usesCompactHeading: Bool
    let blockSpacing: CGFloat
    let headingSpacing: CGFloat

    static func resolve(_ size: DynamicTypeSize) -> SparkChatWelcomeLayout {
        let large = size.isAccessibilitySize
        return SparkChatWelcomeLayout(
            showsSupportingLine: !large,
            usesCompactHeading: large,
            blockSpacing: large ? 14 : 24,
            headingSpacing: large ? 6 : 12
        )
    }
}

/// The first thing an empty conversation offers: three openings, each one tap into the composer.
@MainActor
struct SparkChatWelcomeView: View {
    let choose: (String) -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var layout: SparkChatWelcomeLayout { .resolve(dynamicTypeSize) }

    var body: some View {
        VStack(alignment: .leading, spacing: layout.blockSpacing) {
            heading
            starters
        }
        .frame(maxWidth: 480, alignment: .leading)
        .padding(.bottom, 12)
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: layout.headingSpacing) {
            Text("What would you like to work on?")
                .font(layout.usesCompactHeading ? .headline : .title2.weight(.semibold))
                .tracking(layout.usesCompactHeading ? 0 : -0.4)
                .fixedSize(horizontal: false, vertical: true)
            if layout.showsSupportingLine {
                Text("Ask a question, explore an idea, or work through it together.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var starters: some View {
        VStack(alignment: .leading, spacing: 10) {
            suggestion(
                String(localized: "Explain something"),
                symbol: "lightbulb",
                prompt: String(localized: "Help me understand a concept step by step.")
            )
            suggestion(
                String(localized: "Think through an idea"),
                symbol: "bubble.left.and.bubble.right",
                prompt: String(
                    localized: "Help me think through an idea and compare the options."
                )
            )
            suggestion(
                String(localized: "Write something"),
                symbol: "pencil.line",
                prompt: String(localized: "Help me write a clear first draft.")
            )
        }
    }

    private func suggestion(_ title: String, symbol: String, prompt: String) -> some View {
        Button {
            choose(prompt)
        } label: {
            Label(title, systemImage: symbol)
                .font(.subheadline)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 15)
                .padding(.vertical, 12)
                .background(ChatStyle.surface, in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }
}
