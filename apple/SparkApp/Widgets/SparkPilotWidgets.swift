import AppIntents
import SparkWidgetSupport
import SwiftUI
import WidgetKit

#if os(iOS) && canImport(ActivityKit)
    import ActivityKit

    struct SparkDownloadLiveActivity: Widget {
        var body: some WidgetConfiguration {
            ActivityConfiguration(for: SparkDownloadActivityAttributes.self) { context in
                VStack(alignment: .leading, spacing: 10) {
                    Label("SparkPilot", systemImage: "arrow.down.circle")
                        .font(.caption.weight(.semibold))
                    Text(verbatim: context.state.title(isStale: context.isStale)).font(.headline)
                    if let progress = context.state.progress, !context.isStale {
                        ProgressView(value: progress)
                            .accessibilityLabel("Model download progress")
                            .accessibilityValue(
                                Text(progress, format: .percent.precision(.fractionLength(0)))
                            )
                    }
                }
                .padding(18)
                .activityBackgroundTint(Color.secondary.opacity(0.12))
                .widgetURL(context.attributes.url)
            } dynamicIsland: { context in
                DynamicIsland {
                    DynamicIslandExpandedRegion(.leading) {
                        Label("SparkPilot", systemImage: "arrow.down.circle")
                            .font(.caption.weight(.semibold))
                    }
                    DynamicIslandExpandedRegion(.bottom) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(verbatim: context.state.title(isStale: context.isStale))
                            if let progress = context.state.progress, !context.isStale {
                                ProgressView(value: progress)
                                    .accessibilityLabel("Model download progress")
                                    .accessibilityValue(
                                        Text(
                                            progress,
                                            format: .percent.precision(.fractionLength(0))
                                        )
                                    )
                            }
                        }
                    }
                } compactLeading: {
                    Image(systemName: context.state.systemImage(isStale: context.isStale))
                } compactTrailing: {
                    if let progress = context.state.progress, !context.isStale {
                        Text(progress, format: .percent.precision(.fractionLength(0)))
                            .monospacedDigit()
                    } else {
                        Image(systemName: "ellipsis")
                    }
                } minimal: {
                    Image(systemName: context.state.systemImage(isStale: context.isStale))
                }
                .widgetURL(context.attributes.url)
            }
        }
    }
#endif

struct WidgetSpark: AppEntity {
    let id: String
    let name: String
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Spark or cluster"
    static let defaultQuery = WidgetSparkQuery()
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: LocalizedStringResource(stringLiteral: name))
    }
    static var all: Self { .init(id: "all", name: String(localized: "All Sparks")) }
}

struct WidgetSparkQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [WidgetSpark] {
        let values = try await suggestedEntities()
        return identifiers.map { id in
            values.first { $0.id == id }
                ?? WidgetSpark(id: id, name: String(localized: "Unavailable Spark"))
        }
    }
    func suggestedEntities() async throws -> [WidgetSpark] {
        [.all] + SparkWidgetStore.read().targets.map { WidgetSpark(id: $0.id, name: $0.name) }
    }
    func defaultResult() async -> WidgetSpark? { .all }
}

struct SelectWidgetSpark: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Choose a Spark"
    static let description = IntentDescription("Show all Sparks, one Spark or a cluster.")
    @Parameter(title: "Spark or cluster") var target: WidgetSpark?
}

struct SparkEntry: TimelineEntry {
    let date: Date
    let snapshot: SparkWidgetSnapshot
    let targetID: String?
}

struct SparkProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> SparkEntry {
        SparkEntry(date: Date(), snapshot: .preview(at: Date()), targetID: nil)
    }
    func snapshot(for configuration: SelectWidgetSpark, in context: Context) async -> SparkEntry {
        SparkEntry(
            date: Date(),
            snapshot: context.isPreview ? .preview(at: Date()) : SparkWidgetStore.read(),
            targetID: configuration.target?.id
        )
    }
    func timeline(for configuration: SelectWidgetSpark, in context: Context) async -> Timeline<
        SparkEntry
    > {
        let now = Date(), snapshot = SparkWidgetStore.read()
        // Expire an unconfirmed connection even if the host's next refresh is delayed.
        let expiryInterval = SparkWidgetFreshness.maximumAge + 1
        let nextRefresh = now.addingTimeInterval(SparkWidgetFreshness.refreshInterval)
        let expiryDates = snapshot.targets.flatMap { target in
            [target.observedAt, target.inferenceObservedAt].compactMap { $0 }
                + target.nodes.compactMap(\.observedAt)
        }.map { $0.addingTimeInterval(expiryInterval) }.filter {
            $0 > now && $0 < now.addingTimeInterval(expiryInterval)
        }
        let dates = Set(
            [now, nextRefresh, now.addingTimeInterval(expiryInterval)] + expiryDates
        )
        let entries = dates.sorted().map {
            SparkEntry(date: $0, snapshot: snapshot, targetID: configuration.target?.id)
        }
        return Timeline(entries: entries, policy: .after(nextRefresh))
    }
}

struct SparkEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SparkEntry
    var memoryOnly = false
    private var size: SparkWidgetCardSize {
        switch family {
        case .systemSmall: .small
        case .systemLarge: .large
        case .systemExtraLarge: .extraLarge
        default: .medium
        }
    }
    var body: some View {
        SparkWidgetCard(
            snapshot: entry.snapshot,
            targetID: entry.targetID,
            memoryOnly: memoryOnly,
            size: size,
            date: entry.date
        )
        .containerBackground(.background, for: .widget)
        .widgetURL(
            entry.targetID.flatMap { id in entry.snapshot.targets.first { $0.id == id }?.url }
                ?? URL(string: "sparkpilot://widget?target=all")
        )
    }
}

struct SparkOverviewWidget: Widget {
    let kind = "SparkPilot.Overview"
    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: kind,
            intent: SelectWidgetSpark.self,
            provider: SparkProvider()
        ) { entry in
            SparkEntryView(entry: entry)
        }
        .configurationDisplayName("Spark overview")
        .description("Memory, connection and inference for your Sparks or cluster.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge])
    }
}

struct SparkMemoryWidget: Widget {
    let kind = "SparkPilot.Memory"
    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: kind,
            intent: SelectWidgetSpark.self,
            provider: SparkProvider()
        ) { entry in
            SparkEntryView(entry: entry, memoryOnly: true)
        }
        .configurationDisplayName("Spark memory")
        .description("Used and available memory, with reporting coverage for every cluster.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge])
    }
}

@main
struct SparkPilotWidgets: WidgetBundle {
    var body: some Widget {
        SparkOverviewWidget()
        SparkMemoryWidget()
        #if os(iOS) && canImport(ActivityKit)
            SparkDownloadLiveActivity()
        #endif
    }
}
