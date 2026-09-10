import SwiftUI

/// Where the restart wait has got to.
public enum RetailRestartStage: Sendable, Equatable {
    /// Watching for the Spark to drop off the network; a timed hold applies if it never does.
    case waitingForRestart
    /// It has gone; watching for its SSH port to answer again.
    case restarting
    /// It is back, or the hold ran out; the read-only survey is being tried.
    case checking
}

/// The wait for the Spark's first-boot restart: watch it go and return, then bounded checking until it answers.
public struct RetailRestartProgress: Equatable, Sendable {
    public let startedAt: Date
    public let hold: Duration
    public let limit: Duration
    public let stage: RetailRestartStage
    /// The owner may say the Spark is back once it has been seen restarting, or after this long regardless.
    public let manualCheckAfter: Duration

    public init(
        startedAt: Date,
        hold: Duration,
        limit: Duration,
        stage: RetailRestartStage = .waitingForRestart,
        manualCheckAfter: Duration = .seconds(60)
    ) {
        self.startedAt = startedAt
        self.hold = hold
        self.limit = limit
        self.stage = stage
        self.manualCheckAfter = manualCheckAfter
    }

    public func holdHasElapsed(at date: Date) -> Bool {
        date.timeIntervalSince(startedAt) >= Double(hold.components.seconds)
    }

    /// Delay manual checks for a minute because an early responding port may precede another restart.
    public func manualCheckIsOffered(at date: Date) -> Bool {
        date.timeIntervalSince(startedAt) >= Double(manualCheckAfter.components.seconds)
    }

    public func secondsOfHoldLeft(at date: Date) -> Int {
        max(
            0,
            Int(Double(hold.components.seconds) - date.timeIntervalSince(startedAt).rounded(.down))
        )
    }

    public func fraction(at date: Date) -> Double {
        let limitSeconds = Double(limit.components.seconds)
        guard limitSeconds > 0 else { return 1 }
        return min(1, max(0, date.timeIntervalSince(startedAt) / limitSeconds))
    }

    public var limitMinutes: Int { max(1, Int(limit.components.seconds / 60)) }

    /// Show the countdown before restart and elapsed time afterward.
    public static func status(
        elapsed: TimeInterval,
        hold: Duration,
        limitMinutes: Int,
        stage: RetailRestartStage = .waitingForRestart
    ) -> String {
        let holdSeconds = Double(hold.components.seconds)
        switch stage {
        case .waitingForRestart where elapsed < holdSeconds:
            return String(
                localized: .restartHold(secondsLeft: Int((holdSeconds - elapsed).rounded(.up)))
            )
        case .restarting:
            return String(
                localized:
                    "Your Spark is restarting. It usually restarts twice before it settles; SparkPilot keeps watching."
            )
        case .waitingForRestart, .checking:
            let clock = Duration.seconds(max(0, Int(elapsed)))
                .formatted(.time(pattern: .minuteSecond))
            return String(localized: .restartElapsed(clock: clock, limitMinutes: limitMinutes))
        }
    }
}

/// A countdown, then a clock and a bar; the owner can say the Spark is back once the hold has passed.
struct RetailRestartWait: View {
    let progress: RetailRestartProgress
    let isChecking: Bool
    let detail: String?
    let onSparkIsBack: (() -> Void)?

    var body: some View {
        TimelineView(.periodic(from: progress.startedAt, by: 1)) { context in
            let status = RetailRestartProgress.status(
                elapsed: context.date.timeIntervalSince(progress.startedAt),
                hold: progress.hold,
                limitMinutes: progress.limitMinutes,
                stage: progress.stage
            )
            VStack(spacing: 10) {
                ProgressView(value: progress.fraction(at: context.date))
                    .frame(maxWidth: 320)
                    .accessibilityLabel("Waiting for your Spark to restart")
                    .accessibilityValue(Text(verbatim: status))
                Text(verbatim: status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if let detail {
                    Text(verbatim: detail)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                }
                if let onSparkIsBack, progress.manualCheckIsOffered(at: context.date) {
                    Button(
                        "Check manually now",
                        systemImage: "arrow.clockwise",
                        action: onSparkIsBack
                    )
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(isChecking)
                    .accessibilityIdentifier("spark.setup.restart.back")
                }
            }
            .frame(maxWidth: 440)
        }
    }
}
