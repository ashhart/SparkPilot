import SwiftUI

/// A restrained palette for the watch's OLED display. Color always accompanies a label.
enum SparkWatchStyle {
    static let accent = Color(red: 0.48, green: 0.69, blue: 1)
    static let primary = Color(red: 0.12, green: 0.34, blue: 0.72)
    static let surface = Color(white: 0.10)
    static let healthy = Color(red: 0.43, green: 0.88, blue: 0.68)
    static let warning = Color.orange
    static let radius: CGFloat = 18
    static let gap: CGFloat = 10
}

struct SparkWatchControlStyle: ButtonStyle {
    var prominent = false
    var horizontalPadding: CGFloat = 12
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.medium))
            .frame(maxWidth: .infinity, minHeight: 44)
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, 3)
            .foregroundStyle(
                !enabled ? Color.secondary : configuration.role == .destructive ? .red : .white
            )
            .background(
                prominent && enabled ? SparkWatchStyle.primary : SparkWatchStyle.surface,
                in: RoundedRectangle(cornerRadius: SparkWatchStyle.radius)
            )
            .opacity(configuration.isPressed ? 0.65 : 1)
    }
}

struct SparkWatchPage<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SparkWatchStyle.gap) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolbarTitleDisplayMode(.inline)
    }
}

struct SparkWatchCaption: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.footnote.weight(.medium))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

struct SparkWatchPreviewBadge: View {
    var body: some View {
        Text("Sample data")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .accessibilityLabel("Preview with sample data. Runtime actions are disabled.")
    }
}

struct SparkWatchFeedback: View {
    @Bindable var store: SparkWatchStore
    var body: some View {
        if store.busy || store.pendingID != nil {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.mini)
                    Text(store.busy ? "Working…" : "Waiting for iPhone…")
                        .font(.footnote)
                }
                Button("Stop waiting", role: .cancel) { store.cancel() }
                    .buttonStyle(SparkWatchControlStyle())
                    .disabled(!store.connection.reachable)
            }
        }
        if let error = store.connectionError {
            feedback(error, symbol: "iphone.slash")
        }
        if let error = store.error {
            feedback(error, symbol: "exclamationmark.triangle")
        }
        if let notice = store.notice {
            Text(notice).font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func feedback(_ message: String, symbol: String) -> some View {
        Label(message, systemImage: symbol)
            .font(.footnote)
            .foregroundStyle(SparkWatchStyle.warning)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
    }
}

struct SparkWatchRefresh: View {
    @Bindable var store: SparkWatchStore
    var body: some View {
        Button {
            Task { await store.refresh() }
        } label: {
            Label(store.refreshing ? "Refreshing…" : "Refresh", systemImage: "arrow.clockwise")
        }
        .buttonStyle(SparkWatchControlStyle())
        .disabled(store.isPreview || store.busy || store.refreshing || !store.connection.reachable)
    }
}

/// Debug-only layout coverage without changing the simulator's system settings.
struct SparkWatchPreviewSettings: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--spark-watch-preview"),
                ProcessInfo.processInfo.arguments.contains("--watch-large-type")
            {
                content.dynamicTypeSize(.xxxLarge)
            } else {
                content
            }
        #else
            content
        #endif
    }
}
