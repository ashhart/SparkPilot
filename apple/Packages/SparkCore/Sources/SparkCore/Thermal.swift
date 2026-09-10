import Foundation

/// The guard's thermal rungs; heat may drain or gracefully unload, but never emergency-stops.
public enum SparkThermalState: String, Sendable, Equatable, CaseIterable, Codable {
    case nominal
    case warm
    case hot
    case critical
    /// The guard is running but has no temperature reading.
    case unknown
    /// No memory guard is running on that Spark, or it predates the field.
    case unavailable
}

/// One place to read a Spark's heat, so no view invents its own thresholds (§2.5, §41.5.2.1).
public enum SparkThermalReading {
    /// The guard's shipped policy defaults, used only until a Spark reports its own.
    public static let warmCelsius: Double = 75
    public static let hotCelsius: Double = 84
    public static let criticalCelsius: Double = 90

    /// Prefer the Spark's reported rung; fall back to its thresholds, then to the shipped defaults.
    public static func state(
        reported: String?,
        celsius: Double?,
        warmCelsius: Double? = nil,
        hotCelsius: Double? = nil,
        criticalCelsius: Double? = nil
    ) -> SparkThermalState {
        if let reported, let known = SparkThermalState(rawValue: reported) { return known }
        guard let celsius else { return reported == nil ? .unavailable : .unknown }
        if celsius >= (criticalCelsius ?? Self.criticalCelsius) { return .critical }
        if celsius >= (hotCelsius ?? Self.hotCelsius) { return .hot }
        if celsius >= (warmCelsius ?? Self.warmCelsius) { return .warm }
        return .nominal
    }

    /// The word behind the colour, because colour alone never carries status (§51.1).
    public static func word(_ state: SparkThermalState) -> String {
        switch state {
        case .nominal: String(localized: "Cool")
        case .warm: String(localized: "Warm")
        case .hot: String(localized: "Hot")
        case .critical: String(localized: "Very hot")
        case .unknown: String(localized: "No reading")
        case .unavailable: String(localized: "Not reported")
        }
    }

    /// A rung at or above hot is where the Spark stops admitting new load work.
    public static func needsAttention(_ state: SparkThermalState) -> Bool {
        state == .hot || state == .critical
    }
}
