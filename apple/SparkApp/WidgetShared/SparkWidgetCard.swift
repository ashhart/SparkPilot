import SwiftUI

public enum SparkWidgetCardSize: Sendable { case small, medium, large, extraLarge }

/// A widget line whose colour carries meaning, paired with the symbol that carries the same.
public struct SparkWidgetWarningLine: Equatable, Sendable {
    public let text: String
    public let symbol: String
}

/// The two decisions the card makes about fitting and about not leaning on colour alone.
public enum SparkWidgetCardPresentation {
    /// The small tile has its own row for the name, so a long one wraps rather than truncating.
    public static func titleLineLimit(_ size: SparkWidgetCardSize) -> Int {
        size == .small ? 2 : 1
    }

    /// A name too long even for two lines shrinks to fit instead of ending in an ellipsis.
    public static let titleMinimumScale = 0.75

    /// Members short of a reading, said with a symbol so orange is not the only difference.
    public static func coverageLine(reporting: Int, expected: Int) -> SparkWidgetWarningLine? {
        guard reporting < expected else { return nil }
        return SparkWidgetWarningLine(
            text: String(
                localized: .widgetMemoryCoverage(reporting: reporting, expected: expected)
            ),
            symbol: "exclamationmark.triangle.fill"
        )
    }
}

public struct SparkWidgetCard: View {
    public let snapshot: SparkWidgetSnapshot
    public let targetID: String?
    public let memoryOnly: Bool
    public let size: SparkWidgetCardSize
    public let date: Date

    public init(
        snapshot: SparkWidgetSnapshot,
        targetID: String? = nil,
        memoryOnly: Bool = false,
        size: SparkWidgetCardSize = .medium,
        date: Date = Date()
    ) {
        self.snapshot = snapshot
        self.targetID = targetID
        self.memoryOnly = memoryOnly
        self.size = size
        self.date = date
    }

    private var selected: [SparkWidgetTarget] {
        guard let targetID, targetID != "all" else { return snapshot.targets }
        return snapshot.targets.filter { $0.id == targetID }
    }
    private var title: String {
        selected.count == 1 ? selected[0].name : String(localized: "All Sparks")
    }
    private var memory: SparkWidgetMemory { SparkWidgetMemory(nodes: selected.flatMap(\.nodes)) }
    private var expanded: Bool { size == .large || size == .extraLarge }
    private var timestamp: Date? {
        if memoryOnly { return memory.observedAt }
        return (selected.compactMap(\.observedAt) + [memory.observedAt].compactMap { $0 }).min()
    }
    private var stale: Bool {
        !SparkWidgetFreshness.isRecent(timestamp, at: date)
    }
    private var connectedCount: Int { selected.filter { $0.isConnected(at: date) }.count }
    private var connectionStatus: String {
        if connectedCount == selected.count { return String(localized: "Connected") }
        if connectedCount == 0 { return String(localized: "Offline") }
        return String(
            localized: .widgetOnline(connected: connectedCount, total: selected.count)
        )
    }
    /// How old the reading is, but only once it is past the freshness window.
    private var staleAgeLabel: String? {
        guard stale, let timestamp else { return nil }
        let elapsed = max(0, date.timeIntervalSince(timestamp))
        return Duration.seconds(elapsed).formatted(
            .units(allowed: [.days, .hours, .minutes], maximumUnitCount: 1)
        )
    }

    private var accent: Color {
        stale ? .secondary : (memory.fraction ?? 0) >= 0.9 ? .orange : .blue
    }

    public var body: some View {
        if snapshot.isPrivate || selected.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: snapshot.isPrivate ? "lock.fill" : "square.stack.3d.up")
                    .font(.title2).foregroundStyle(.blue)
                Text("SparkPilot").font(.headline)
                Text(
                    snapshot.isPrivate
                        ? "Open SparkPilot to view your Sparks."
                        : targetID != nil && targetID != "all"
                            ? "This Spark is no longer available."
                            : "Open SparkPilot to add a Spark."
                )
                .font(.caption).foregroundStyle(.secondary).fixedSize(
                    horizontal: false,
                    vertical: true
                )
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: expanded ? 16 : 10) {
                HStack(spacing: 6) {
                    Image(
                        systemName: selected.contains(where: \.isCluster) || selected.count > 1
                            ? "square.stack.3d.up.fill" : "desktopcomputer"
                    )
                    .foregroundStyle(accent).accessibilityHidden(true)
                    Text(title).font(.subheadline.weight(.semibold))
                        .lineLimit(SparkWidgetCardPresentation.titleLineLimit(size))
                        .minimumScaleFactor(SparkWidgetCardPresentation.titleMinimumScale)
                    Spacer(minLength: 0)
                    if size != .small {
                        Text(memoryOnly ? "Memory" : "Overview").font(.caption2).foregroundStyle(
                            .secondary
                        )
                    }
                }
                if size == .small {
                    memoryReading
                    if !memoryOnly, let name = activeModelName {
                        Text(name).font(.caption2.weight(.medium)).lineLimit(2)
                            .minimumScaleFactor(0.85)
                    }
                } else {
                    HStack(alignment: .top, spacing: 24) {
                        memoryReading.frame(maxWidth: .infinity, alignment: .leading)
                        VStack(alignment: .leading, spacing: 8) {
                            if memoryOnly {
                                metric(String(localized: "Available"), value: availableLabel)
                                metric(
                                    String(localized: "Reporting"),
                                    value: String(
                                        localized: .widgetMemoryCoverage(
                                            reporting: memory.reporting,
                                            expected: memory.expected
                                        )
                                    )
                                )
                            } else {
                                metric(String(localized: "Connection"), value: connectionLabel)
                                if selected.count == 1 {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text("Inference").font(.caption2).foregroundStyle(
                                            .secondary
                                        )
                                        if let name = activeModelName {
                                            Text(name).font(.caption.weight(.semibold)).lineLimit(2)
                                                .minimumScaleFactor(0.85)
                                            Text(inferenceLabel).font(.caption2)
                                                .foregroundStyle(.secondary).lineLimit(1)
                                        } else {
                                            Text(inferenceLabel).font(.caption.weight(.semibold))
                                                .lineLimit(2)
                                        }
                                    }
                                    .accessibilityElement(children: .combine)
                                } else {
                                    metric(
                                        String(localized: "Targets"),
                                        value: selected.count.formatted()
                                    )
                                }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if expanded {
                    Divider()
                    VStack(spacing: 12) {
                        let nodes = uniqueNodes
                        ForEach(Array(nodes.prefix(size == .extraLarge ? 6 : 4))) { node in
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(node.name).font(.caption.weight(.medium)).lineLimit(1)
                                    if let used = node.usedBytes, let total = node.totalBytes {
                                        meter(
                                            Double(used)
                                                / Double(
                                                    SparkInstalledMemoryCapacity.installedBytes(
                                                        reportedBytes: total
                                                    )
                                                )
                                        )
                                        .accessibilityLabel("Memory used")
                                    }
                                }
                                Spacer(minLength: 12)
                                Text(
                                    node.usedBytes.map { Self.gigabytes($0) }
                                        ?? String(localized: "Unknown")
                                )
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                        if nodes.count > (size == .extraLarge ? 6 : 4) {
                            Text("Open SparkPilot for every member").font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer(minLength: 0)
                HStack(spacing: 4) {
                    Image(
                        systemName: connectedCount > 0 ? "checkmark.circle.fill" : "wifi.slash"
                    )
                    .foregroundStyle(connectedCount > 0 ? .green : .secondary)
                    .accessibilityHidden(true)
                    Text(connectionStatus).lineLimit(1)
                }.font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .privacySensitive()
        }
    }

    private var memoryReading: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let used = memory.usedBytes {
                Text(Self.gigabytes(used)).font(
                    .system(size: size == .small ? 28 : 32, weight: .semibold, design: .rounded)
                )
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
                if let total = memory.totalBytes {
                    Text(
                        LocalizedStringResource.widgetMemoryTotal(
                            Self.gigabytes(total, paddingFraction: false)
                        )
                    ).font(
                        .caption
                    ).foregroundStyle(.secondary)
                    meter(memory.fraction ?? 0).padding(.top, 4)
                        .accessibilityLabel("Memory used")
                        .accessibilityValue(
                            Text(
                                LocalizedStringResource.widgetMemoryValue(
                                    used: Self.gigabytes(used),
                                    total: Self.gigabytes(total, paddingFraction: false)
                                )
                            )
                        )
                }
                if let age = staleAgeLabel {
                    // §2.5's honest cached state: a number the app could not refresh says its age.
                    Text(LocalizedStringResource.widgetLastChecked(age))
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                if let line = SparkWidgetCardPresentation.coverageLine(
                    reporting: memory.reporting,
                    expected: memory.expected
                ) {
                    Label {
                        Text(line.text)
                    } icon: {
                        Image(systemName: line.symbol)
                    }
                    .font(.caption2).foregroundStyle(.orange)
                }
            } else {
                Text("Unknown").font(.title2.weight(.semibold))
                Text("No memory reading").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var availableLabel: String {
        guard let total = memory.totalBytes, let used = memory.usedBytes else {
            return String(localized: "Unknown")
        }
        return Self.gigabytes(total - used)
    }
    private var connectionLabel: String {
        if selected.count == 1, selected[0].isConnected(at: date) {
            return selected[0].connection
        }
        return connectionStatus
    }
    private var inferenceLabel: String {
        guard let target = selected.first, target.isConnected(at: date),
            SparkWidgetFreshness.isRecent(target.inferenceObservedAt, at: date)
        else { return String(localized: "Unknown") }
        return target.inference
    }
    private var activeModelName: String? {
        guard selected.count == 1 else { return nil }
        return selected[0].activeModelName(at: date)
    }
    private var uniqueNodes: [SparkWidgetNode] {
        Dictionary(
            selected.flatMap(\.nodes).map { ($0.id, $0) },
            uniquingKeysWith: {
                ($0.observedAt ?? .distantPast) >= ($1.observedAt ?? .distantPast) ? $0 : $1
            }
        ).values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    private func meter(_ fraction: Double) -> some View {
        GeometryReader { geometry in
            Capsule().fill(accent.opacity(0.15))
                .overlay(alignment: .leading) {
                    Capsule().fill(accent).frame(
                        width: geometry.size.width * min(1, max(0, fraction))
                    )
                }
        }.frame(height: 5)
    }
    private func metric(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption.weight(.semibold)).lineLimit(2)
        }
    }
    private static func gigabytes(_ bytes: Int64, paddingFraction: Bool = true) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = .useGB
        formatter.countStyle = .decimal
        formatter.allowsNonnumericFormatting = false
        formatter.zeroPadsFractionDigits = paddingFraction
        return formatter.string(fromByteCount: bytes)
    }
}

extension SparkWidgetSnapshot {
    /// Gallery illustrations only; never used as a fallback for a real widget.
    public static func preview(at date: Date) -> SparkWidgetSnapshot {
        SparkWidgetSnapshot(targets: [
            SparkWidgetTarget(
                id: "preview",
                name: "Studio cluster",
                isCluster: true,
                nodes: [
                    SparkWidgetNode(
                        id: "a",
                        name: "Desk Spark",
                        totalBytes: 128_000_000_000,
                        availableBytes: 44_000_000_000,
                        observedAt: date
                    ),
                    SparkWidgetNode(
                        id: "b",
                        name: "Studio Spark",
                        totalBytes: 128_000_000_000,
                        availableBytes: 68_000_000_000,
                        observedAt: date
                    ),
                ],
                connection: String(localized: "Connected"),
                isConnected: true,
                observedAt: date,
                inference: String(localized: "Running"),
                inferenceObservedAt: date,
                activeModelName: "Nemotron 3.5 Lightning 30B"
            )
        ])
    }
}
