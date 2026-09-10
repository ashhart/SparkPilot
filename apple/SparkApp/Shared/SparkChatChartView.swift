import SwiftUI

/// Title, chart and any note the chart could not pin to a position, laid out the same everywhere.
struct SparkChartCard: View {
    let spec: SparkChartSpec
    var isCompact = true
    @ScaledMetric(relativeTo: .body) private var compactHeight: CGFloat = 190

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(spec.title)
                .font(isCompact ? .subheadline.weight(.semibold) : .title3.weight(.semibold))
                .accessibilityHidden(true)
            SparkChartPlot(spec: spec)
                .frame(minHeight: isCompact ? compactHeight : 300)
                .accessibilityElement()
                .accessibilityLabel(spec.title)
                .accessibilityValue(SparkChartAccessibility.summary(spec))
                .accessibilityChartDescriptor(SparkChartDescriptor(spec: spec))
            ForEach(loose.indices, id: \.self) { index in
                Text(loose[index]).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var loose: [String] {
        spec.annotations.filter { $0.x == nil && $0.y == nil }.map(\.text)
    }
}

/// A chart inside the transcript: readable in place, openable full screen, shareable as an image.
@MainActor
struct SparkChatChartView: View {
    let spec: SparkChartSpec
    @Environment(\.colorScheme) private var scheme
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SparkChartCard(spec: spec)
                .contentShape(Rectangle())
                .onTapGesture { isExpanded = true }
            HStack(spacing: 2) {
                Button {
                    isExpanded = true
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.callout)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open chart full screen")
                SparkChartActions(transfer: transfer, title: spec.title)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(ChatStyle.surface, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(ChatStyle.border))
        .accessibilityElement(children: .contain)
        #if os(iOS)
            .fullScreenCover(isPresented: $isExpanded) { SparkChartDetailView(spec: spec) }
        #else
            .sheet(isPresented: $isExpanded) { SparkChartDetailView(spec: spec) }
        #endif
    }

    private var transfer: SparkChartTransfer {
        SparkChartTransfer(spec: spec, scheme: scheme)
    }
}

/// Share and copy render the image only when tapped, so a long transcript never renders one.
@MainActor
struct SparkChartActions: View {
    let transfer: SparkChartTransfer
    let title: String
    @State private var copied = false

    var body: some View {
        ShareLink(item: transfer, preview: SharePreview(title)) {
            Image(systemName: "square.and.arrow.up")
                .font(.callout)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Share chart as an image")
        Button {
            copied = SparkChartPasteboard.copy(transfer)
        } label: {
            Image(systemName: copied ? "checkmark" : "document.on.document")
                .font(.callout)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(copied ? Text("Copied") : Text("Copy chart as an image"))
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}

@MainActor
struct SparkChartDetailView: View {
    let spec: SparkChartSpec
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        NavigationStack {
            ScrollView {
                SparkChartCard(spec: spec, isCompact: false)
                    .padding(20)
                    .frame(maxWidth: ChatStyle.readingWidth)
                    .frame(maxWidth: .infinity)
            }
            .background(ChatStyle.canvas)
            .navigationTitle("Chart")
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItemGroup(placement: .automatic) {
                    SparkChartActions(
                        transfer: SparkChartTransfer(spec: spec, scheme: scheme),
                        title: spec.title
                    )
                }
            }
        }
    }
}
