import SwiftUI

/// The bounded post-setup search: when it began and how long it may run.
public struct RetailRediscoveryProgress: Equatable, Sendable {
    public let startedAt: Date
    public let limit: Duration

    public init(startedAt: Date, limit: Duration) {
        self.startedAt = startedAt
        self.limit = limit
    }

    public func fraction(at date: Date) -> Double {
        let limitSeconds = Double(limit.components.seconds)
        guard limitSeconds > 0 else { return 1 }
        return min(1, max(0, date.timeIntervalSince(startedAt) / limitSeconds))
    }

    public var limitMinutes: Int { max(1, Int(limit.components.seconds / 60)) }

    /// One line for the waiting screen: elapsed time against the limit.
    public static func status(elapsed: TimeInterval, limitMinutes: Int) -> String {
        let clock = Duration.seconds(max(0, Int(elapsed)))
            .formatted(.time(pattern: .minuteSecond))
        return String(localized: .rediscoveryElapsed(clock: clock, limitMinutes: limitMinutes))
    }
}

/// An elapsed clock and a determinate bar for the wait, with Look Again available the whole time.
struct RetailRediscoveryWait: View {
    let progress: RetailRediscoveryProgress
    let onLookAgain: (() -> Void)?

    var body: some View {
        TimelineView(.periodic(from: progress.startedAt, by: 1)) { context in
            let status = RetailRediscoveryProgress.status(
                elapsed: context.date.timeIntervalSince(progress.startedAt),
                limitMinutes: progress.limitMinutes
            )
            VStack(spacing: 10) {
                ProgressView(value: progress.fraction(at: context.date))
                    .frame(maxWidth: 320)
                    .accessibilityLabel("Looking for your Spark")
                    .accessibilityValue(Text(verbatim: status))
                Text(verbatim: status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if let onLookAgain {
                    Button("Look Again", systemImage: "arrow.clockwise", action: onLookAgain)
                        .buttonStyle(.bordered)
                }
            }
            .frame(maxWidth: 440)
        }
    }
}
