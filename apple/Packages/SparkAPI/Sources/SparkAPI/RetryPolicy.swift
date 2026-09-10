import Foundation
@_spi(SparkInternal) import SparkTransport

/// The §38.2 automatic-retry rule: base 250 ms, multiplier 2, maximum 8 s, full jitter, at most five attempts.
public struct SparkRetryPolicy: Sendable, Equatable {
    public let maximumAttempts: Int
    public let baseDelay: TimeInterval
    public let multiplier: Double
    public let maximumDelay: TimeInterval

    public init(
        maximumAttempts: Int = 5,
        baseDelay: TimeInterval = 0.25,
        multiplier: Double = 2,
        maximumDelay: TimeInterval = 8
    ) {
        self.maximumAttempts = max(1, maximumAttempts)
        self.baseDelay = baseDelay
        self.multiplier = multiplier
        self.maximumDelay = maximumDelay
    }

    public static let standard = SparkRetryPolicy()

    /// Never retry automatically; used where a single-use proof or an unsafe body forbids replay.
    public static let none = SparkRetryPolicy(maximumAttempts: 1)

    /// Timing, backpressure and the transient 5xx; 501, 505 and 511 cannot change on a repeat.
    public static func statusIsRetryable(_ status: Int) -> Bool {
        [408, 425, 429, 500, 502, 503, 504].contains(status)
    }

    /// A transport failure is retryable unless the route itself is wrong: a bad pin, a redirect or plaintext.
    public static func transportFailureIsRetryable(_ error: any Error) -> Bool {
        if error is CancellationError { return false }
        guard let transport = error as? PinnedTransportError else { return true }
        switch transport {
        case .unreachable, .nonHTTPResponse: return true
        case .certificateRejected, .insecureScheme, .redirected, .malformedPin: return false
        }
    }

    /// The uncapped exponential ceiling for the delay after `attempt` completed attempts.
    public func ceiling(afterAttempt attempt: Int) -> TimeInterval {
        let exponent = pow(multiplier, Double(max(0, attempt - 1)))
        return min(maximumDelay, baseDelay * exponent)
    }

    /// Full jitter draws below the ceiling unless the Spark set the pace with `Retry-After`.
    public func delay(
        afterAttempt attempt: Int,
        retryAfter: TimeInterval?,
        jitter: (TimeInterval) -> TimeInterval
    ) -> TimeInterval {
        if let retryAfter, retryAfter >= 0 { return min(retryAfter, maximumDelay) }
        return jitter(ceiling(afterAttempt: attempt))
    }
}

/// Read `Retry-After` in both documented forms without inventing a delay when it is absent or malformed.
public enum SparkRetryAfter {
    private static let httpDateFormats = [
        "EEE, dd MMM yyyy HH:mm:ss zzz",
        "EEEE, dd-MMM-yy HH:mm:ss zzz",
    ]

    public static func seconds(from header: String?, now: Date = Date()) -> TimeInterval? {
        guard let header else { return nil }
        let trimmed = header.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return nil }
        if let delta = TimeInterval(trimmed) { return delta >= 0 ? delta : nil }
        for format in httpDateFormats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "GMT")
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) {
                return max(0, date.timeIntervalSince(now))
            }
        }
        return nil
    }
}
