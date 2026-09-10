import Foundation
import Observation
import SparkAPI

/// Where the history on screen came from, and whether it can be trusted now.
public enum SparkTelemetryHistoryOrigin: Equatable, Sendable {
    /// Read from the Spark, which records whether or not this app is open.
    case runtime
    /// The Spark could not be reached; this is what this device saw itself.
    case deviceCache
    /// Nothing to show, and the reason.
    case none(SparkTelemetryHistoryAbsence)
}

/// Distinguishes missing-history reasons so an empty chart cannot imply that no activity occurred.
public enum SparkTelemetryHistoryAbsence: Equatable, Sendable {
    /// Functional telemetry consent is off, so the Spark records nothing.
    case recordingDisabled
    /// Recording is on and has not produced anything yet.
    case noSamplesYet
    /// The Spark could not be reached and this device has nothing cached.
    case unreachable
}

/// One point on a history chart, from either source.
public struct SparkTelemetryHistoryPoint: Equatable, Sendable, Identifiable {
    public let observedAt: Date
    /// `true` when this point is one ten-second reading rather than a fold.
    public let isRaw: Bool
    /// How many ten-second readings this point represents.
    public let sampleCount: Int
    public let cpuUtilisation: Double?
    public let memoryAvailableBytes: Int64?
    public let acceleratorUtilisation: Double?
    public let activeRequests: Double?
    public let queueDepth: Double?
    public let tokensPerSecond: Double?

    /// Include resolution in telemetry point identity so raw and aggregated samples may share a timestamp without collision.
    public var id: String { "\(isRaw ? "raw" : "minute")@\(observedAt.timeIntervalSince1970)" }
}

/// Uses runtime-recorded history with an explicitly labelled device-cache fallback when the Spark is unreachable.
@MainActor
@Observable
public final class SparkTelemetryHistoryModel {
    public private(set) var points: [SparkTelemetryHistoryPoint] = []
    public private(set) var origin: SparkTelemetryHistoryOrigin = .none(.noSamplesYet)
    public private(set) var latestObservedAt: Date?
    public private(set) var isLoading = false

    @ObservationIgnored private let load:
        @MainActor (URL) async throws -> GeneratedAPI.TelemetryHistory
    @ObservationIgnored private let cached: @MainActor () -> [SparkTelemetryHistoryPoint]
    @ObservationIgnored private var lastFetch: Date?
    @ObservationIgnored private let now: @Sendable () -> Date

    /// Reuses history between runtime sampling intervals to avoid requests that cannot yield another bucket.
    public static let refreshInterval: TimeInterval = 60

    public init(
        load: @escaping @MainActor (URL) async throws -> GeneratedAPI.TelemetryHistory,
        cached: @escaping @MainActor () -> [SparkTelemetryHistoryPoint] = { [] },
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.load = load
        self.cached = cached
        self.now = now
    }

    /// Whether enough time has passed to ask the Spark again.
    public func needsRefresh() -> Bool {
        guard let lastFetch else { return true }
        return now().timeIntervalSince(lastFetch) >= Self.refreshInterval
    }

    /// Fetch on entering the dashboard, and at the low cadence after that.
    public func refresh(route: URL, force: Bool = false) async {
        guard force || needsRefresh(), !isLoading else { return }
        isLoading = true
        // Record history attempts before the request so fast failures cannot trigger one-second retry loops.
        lastFetch = now()
        defer { isLoading = false }
        do {
            let history = try await load(route)
            points = history.rows.compactMap(Self.point).sorted { $0.observedAt < $1.observedAt }
            latestObservedAt = Self.instant(history.latestObservedAt)
            origin =
                if !history.recording {
                    .none(.recordingDisabled)
                } else if points.isEmpty {
                    .none(.noSamplesYet)
                } else {
                    .runtime
                }
        } catch {
            // Present cached observations as historical evidence when the Spark is unreachable.
            let fallback = cached()
            points = fallback
            origin = fallback.isEmpty ? .none(.unreachable) : .deviceCache
            latestObservedAt = fallback.last?.observedAt
        }
    }

    private static func instant(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: raw)
            ?? {
                let plain = ISO8601DateFormatter()
                plain.formatOptions = [.withInternetDateTime]
                return plain.date(from: raw)
            }()
    }

    private static func point(
        _ row: GeneratedAPI.TelemetryHistoryRow
    ) -> SparkTelemetryHistoryPoint? {
        guard let observedAt = instant(row.observedAt) else { return nil }
        return SparkTelemetryHistoryPoint(
            observedAt: observedAt,
            isRaw: row.resolution == .raw,
            sampleCount: row.sampleCount,
            cpuUtilisation: row.cpuUtilisation,
            memoryAvailableBytes: row.memoryAvailableBytes.map(Int64.init),
            acceleratorUtilisation: row.acceleratorUtilisation,
            activeRequests: row.activeRequests,
            queueDepth: row.queueDepth,
            tokensPerSecond: row.tokensPerSecond
        )
    }
}

/// What the history area says when there is nothing to draw.
public enum SparkTelemetryHistoryCopy {
    public static func emptyMessage(_ absence: SparkTelemetryHistoryAbsence) -> String {
        switch absence {
        case .recordingDisabled:
            String(
                localized: """
                    This Spark is not recording history. Turn on functional \
                    diagnostics in its privacy settings to keep a local trend.
                    """
            )
        case .noSamplesYet:
            String(localized: "This Spark has not recorded a reading yet.")
        case .unreachable:
            String(
                localized: """
                    The Spark could not be reached, and this device has no \
                    saved readings for it.
                    """
            )
        }
    }

    /// Label cached-chart gaps so missing observations cannot be mistaken for inactivity.
    public static var deviceCacheNotice: String {
        String(
            localized: """
                Showing what this device saw while it was open. The Spark's own \
                record is unavailable right now.
                """
        )
    }

    /// Said when the newest reading is older than the sampler's cadence.
    public static func staleNotice(_ age: TimeInterval) -> String {
        String(localized: .historyLastReading(SparkDuration.brief(seconds: Int64(age))))
    }
}
