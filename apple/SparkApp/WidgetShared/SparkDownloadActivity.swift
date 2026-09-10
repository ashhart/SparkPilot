import Foundation

/// Public Lock Screen data deliberately excludes model names, routes and credentials.
public struct SparkDownloadActivityState: Codable, Hashable, Sendable {
    public enum Phase: String, Codable, Sendable {
        case downloading, waiting, succeeded, failed, cancelled
    }
    public let phase: Phase
    public let progress: Double?
    public let observedAt: Date

    public init(phase: Phase, progress: Double?, observedAt: Date) {
        self.phase = phase
        self.progress =
            phase == .succeeded
            ? 1
            : [.failed, .cancelled].contains(phase)
                ? nil
                : progress.flatMap { $0.isFinite && (0...1).contains($0) ? $0 : nil }
        self.observedAt = observedAt
    }

    public var isTerminal: Bool { [.succeeded, .failed, .cancelled].contains(phase) }
    public var staleAt: Date { observedAt.addingTimeInterval(30) }

    public func systemImage(isStale: Bool) -> String {
        if isStale && !isTerminal { return "clock" }
        switch phase {
        case .succeeded: return "checkmark.circle"
        case .failed: return "exclamationmark.triangle"
        case .cancelled: return "xmark.circle"
        case .waiting: return "clock"
        case .downloading: return "arrow.down.circle"
        }
    }

    public func title(isStale: Bool) -> String {
        if isStale && !isTerminal { return String(localized: "Open SparkPilot to refresh") }
        switch phase {
        case .downloading: return String(localized: "Downloading a model")
        case .waiting: return String(localized: "Waiting to download")
        case .succeeded: return String(localized: "Model installed")
        case .failed: return String(localized: "Download needs attention")
        case .cancelled: return String(localized: "Download cancelled")
        }
    }
}

#if os(iOS) && canImport(ActivityKit)
    import ActivityKit

    public struct SparkDownloadActivityAttributes: ActivityAttributes {
        public typealias ContentState = SparkDownloadActivityState
        public let targetID: String
        public let operationID: UUID

        public init(targetID: String, operationID: UUID) {
            self.targetID = targetID
            self.operationID = operationID
        }

        public var url: URL? {
            var url = URLComponents()
            url.scheme = "sparkpilot"
            url.host = "widget"
            url.queryItems = [URLQueryItem(name: "target", value: targetID)]
            return url.url
        }
    }
#endif
