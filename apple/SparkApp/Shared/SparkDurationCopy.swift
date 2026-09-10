import Foundation

/// Formats elapsed durations using locale-aware units at the coarse precision useful for Spark uptime.
enum SparkDuration {
    /// An uptime, coarsened to the two largest units that carry information.
    static func coarse(seconds: Int64) -> String {
        let duration = Duration.seconds(seconds)
        let allowed: Set<Duration.UnitsFormatStyle.Unit> =
            switch seconds {
            case 86_400...: [.days, .hours]
            case 3_600...: [.hours, .minutes]
            default: [.minutes]
            }
        // Retain a zero smaller unit and truncate values so the display never claims time that has not elapsed.
        return duration.formatted(
            .units(
                allowed: allowed,
                width: .narrow,
                maximumUnitCount: 2,
                zeroValueUnits: .show(length: 1),
                fractionalPart: .hide(rounded: .towardZero)
            )
        )
    }

    /// An age in seconds, for "Cached 30s".
    static func brief(seconds: Int64) -> String {
        Duration.seconds(seconds).formatted(.units(allowed: [.seconds], width: .narrow))
    }
}
