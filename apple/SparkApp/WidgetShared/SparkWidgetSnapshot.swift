import Foundation

/// Widget status describes a recent authenticated check, not a persistent socket.
public enum SparkWidgetFreshness {
    public static let refreshInterval: TimeInterval = 15 * 60
    public static let maximumAge: TimeInterval = 30 * 60

    public static func isRecent(_ observedAt: Date?, at date: Date) -> Bool {
        guard let observedAt else { return false }
        return date.timeIntervalSince(observedAt) <= maximumAge
            && observedAt <= date.addingTimeInterval(60)
    }
}

/// Shared by the app and widgets so installed capacity uses the same units everywhere.
public enum SparkInstalledMemoryCapacity {
    private static let binaryGigabyte: Int64 = 1 << 30
    private static let decimalGigabyte: Int64 = 1_000_000_000
    private static let supportedGigabytes: [Int64] = [32, 64, 128, 256, 512, 1_024]

    public static func installedBytes(reportedBytes: Int64) -> Int64 {
        guard reportedBytes > 0 else { return reportedBytes }
        let reportedGiB = Double(reportedBytes) / Double(binaryGigabyte)
        guard
            let capacity = supportedGigabytes.first(where: { candidate in
                reportedGiB <= Double(candidate) && reportedGiB >= Double(candidate) * 0.90
            })
        else { return reportedBytes }
        return capacity * decimalGigabyte
    }
}

/// The extension receives display data only, never routes, certificates or signing keys.
public struct SparkWidgetNode: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var totalBytes: Int64?
    public var availableBytes: Int64?
    public var observedAt: Date?

    public init(
        id: String,
        name: String,
        totalBytes: Int64? = nil,
        availableBytes: Int64? = nil,
        observedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.observedAt = observedAt
        if let totalBytes, let availableBytes, totalBytes > 0,
            availableBytes >= 0, availableBytes <= totalBytes
        {
            self.totalBytes = totalBytes
            self.availableBytes = availableBytes
        } else {
            self.totalBytes = nil
            self.availableBytes = nil
        }
    }

    public var usedBytes: Int64? {
        guard let totalBytes, let availableBytes, totalBytes > 0,
            (0...totalBytes).contains(availableBytes)
        else { return nil }
        return totalBytes - availableBytes
    }
}

public struct SparkWidgetTarget: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var isCluster: Bool
    public var nodes: [SparkWidgetNode]
    public var connection: String
    public var isConnected: Bool
    public var observedAt: Date?
    public var inference: String
    public var inferenceObservedAt: Date?
    public var temperature: Double?
    public var activeModelName: String?

    public init(
        id: String,
        name: String,
        isCluster: Bool,
        nodes: [SparkWidgetNode],
        connection: String,
        isConnected: Bool,
        observedAt: Date?,
        inference: String,
        inferenceObservedAt: Date? = nil,
        temperature: Double? = nil,
        activeModelName: String? = nil
    ) {
        self.id = id
        self.name = name
        self.isCluster = isCluster
        self.nodes = nodes
        self.connection = connection
        self.isConnected = isConnected
        self.observedAt = observedAt
        self.inference = inference
        self.inferenceObservedAt = inferenceObservedAt
        self.temperature = temperature
        self.activeModelName = activeModelName
    }

    public var url: URL {
        var parts = URLComponents()
        parts.scheme = "sparkpilot"
        parts.host = "widget"
        parts.queryItems = [URLQueryItem(name: "target", value: id)]
        return parts.url!
    }

    public func isConnected(at date: Date) -> Bool {
        isConnected && SparkWidgetFreshness.isRecent(observedAt, at: date)
    }

    public func activeModelName(at date: Date) -> String? {
        guard isConnected(at: date),
            SparkWidgetFreshness.isRecent(inferenceObservedAt, at: date)
        else { return nil }
        return activeModelName
    }
}

public struct SparkWidgetSnapshot: Codable, Equatable, Sendable {
    public var version = 1
    public var targets: [SparkWidgetTarget]
    public var isPrivate: Bool
    public init(targets: [SparkWidgetTarget] = [], isPrivate: Bool = false) {
        self.targets = isPrivate ? [] : targets
        self.isPrivate = isPrivate
    }
    public static let empty = SparkWidgetSnapshot()

    public static func targetID(from url: URL) -> String? {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
            parts.scheme == "sparkpilot", parts.host == "widget",
            parts.path.isEmpty, parts.user == nil, parts.password == nil, parts.port == nil,
            parts.fragment == nil, let items = parts.queryItems, items.count == 1,
            items[0].name == "target", let value = items[0].value,
            !value.isEmpty, value.utf8.count <= 256
        else { return nil }
        return value
    }
}

public struct SparkWidgetMemory: Equatable, Sendable {
    public let totalBytes: Int64?
    public let usedBytes: Int64?
    public let reporting: Int
    public let expected: Int
    public let observedAt: Date?

    public init(nodes: [SparkWidgetNode]) {
        // A physical Spark contributes once, even if the library contains overlapping targets.
        let unique = Dictionary(
            nodes.map { ($0.id, $0) },
            uniquingKeysWith: { first, second in
                (first.observedAt ?? .distantPast) >= (second.observedAt ?? .distantPast)
                    ? first : second
            }
        ).values
        let valid = unique.filter { $0.usedBytes != nil && $0.observedAt != nil }
        expected = unique.count
        reporting = valid.count
        observedAt = valid.compactMap(\.observedAt).min()
        var total: Int64 = 0, used: Int64 = 0
        for node in valid {
            let nextTotal = total.addingReportingOverflow(
                SparkInstalledMemoryCapacity.installedBytes(reportedBytes: node.totalBytes!)
            )
            let nextUsed = used.addingReportingOverflow(node.usedBytes!)
            guard !nextTotal.overflow, !nextUsed.overflow else {
                totalBytes = nil
                usedBytes = nil
                return
            }
            total = nextTotal.partialValue
            used = nextUsed.partialValue
        }
        totalBytes = valid.isEmpty ? nil : total
        usedBytes = valid.isEmpty ? nil : used
    }

    public var fraction: Double? {
        guard let usedBytes, let totalBytes, totalBytes > 0 else { return nil }
        return min(1, max(0, Double(usedBytes) / Double(totalBytes)))
    }
}

public enum SparkWidgetStore {
    public static let groupID = "group.com.sparkfabric.Spark"
    public static let kinds = ["SparkPilot.Overview", "SparkPilot.Memory"]

    public static var fileURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)?
            .appendingPathComponent("widget-overview-v1.json")
    }

    public static func read(from url: URL? = fileURL) -> SparkWidgetSnapshot {
        guard let url, let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
            size <= 1_048_576, let data = try? Data(contentsOf: url),
            let value = try? JSONDecoder().decode(SparkWidgetSnapshot.self, from: data),
            value.version == 1
        else { return .empty }
        return value.isPrivate ? SparkWidgetSnapshot(isPrivate: true) : value
    }

    /// Returns true only when data changed, allowing callers to budget timeline reloads.
    @discardableResult
    public static func write(_ snapshot: SparkWidgetSnapshot, to url: URL? = fileURL) throws -> Bool
    {
        guard let url else { return false }
        if read(from: url) == snapshot, FileManager.default.fileExists(atPath: url.path) {
            return false
        }
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: url, options: .atomic)
        #if os(iOS)
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: url.path
            )
        #endif
        return true
    }
}
