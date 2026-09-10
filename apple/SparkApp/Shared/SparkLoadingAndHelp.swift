import SwiftUI

/// Shows a skeleton only without cached content so refreshes never blank an existing screen.
public struct SparkSkeletonList: View {
    private let rowCount: Int
    private let accessibilityLabel: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPulsing = false

    public init(rowCount: Int = 3, accessibilityLabel: String) {
        self.rowCount = max(1, rowCount)
        self.accessibilityLabel = accessibilityLabel
    }

    public var body: some View {
        VStack(spacing: 12) {
            ForEach(0..<rowCount, id: \.self) { index in
                skeletonCard(shortLastLine: index.isMultiple(of: 2))
            }
        }
        .opacity(reduceMotion ? 0.62 : (isPulsing ? 0.38 : 0.72))
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 0.9).repeatForever(autoreverses: true),
            value: isPulsing
        )
        .onAppear {
            guard !reduceMotion else { return }
            isPulsing = true
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private func skeletonCard(shortLastLine: Bool) -> some View {
        HStack(alignment: .top, spacing: 14) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.quaternary)
                .frame(width: 42, height: 42)
            VStack(alignment: .leading, spacing: 10) {
                Capsule()
                    .fill(.quaternary)
                    .frame(width: 172, height: 15)
                Capsule()
                    .fill(.quaternary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 11)
                Capsule()
                    .fill(.quaternary)
                    .frame(maxWidth: shortLastLine ? 210 : 290)
                    .frame(height: 11)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 14))
        .accessibilityHidden(true)
    }
}

/// A help control that works with a tap on iPhone and iPad and a hover on Mac.
public struct SparkTooltipButton: View {
    private let title: String
    private let message: String

    @State private var isPresented = false

    public init(title: String, message: String) {
        self.title = title
        self.message = message
    }

    public var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: "info.circle")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(message)
        .accessibilityLabel(Text(.aboutResource(title)))
        .accessibilityHint(message)
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.headline)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(idealWidth: 280, maxWidth: 320, alignment: .leading)
            #if os(iOS)
                .presentationCompactAdaptation(.popover)
            #endif
        }
    }
}

extension View {
    func sparkHelp(_ message: String) -> some View {
        help(message)
            .accessibilityHint(message)
    }
}
