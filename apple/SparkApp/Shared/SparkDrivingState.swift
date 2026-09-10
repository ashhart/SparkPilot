import Foundation

/// Whether the phone should let the owner type, decided from the car rather than guessed.
public enum SparkDrivingMode: String, Equatable, Sendable {
    /// No car is connected, so the app behaves exactly as it always has.
    case notDriving
    /// Connected to a car that is stopped; typing is allowed and voice stays first.
    case parked
    /// The car is moving; text entry is paused and voice is the only way in.
    case moving
}

/// What the app can observe about the car at one instant.
public struct SparkDrivingSignals: Equatable, Sendable {
    public var carPlayConnected: Bool
    /// The car itself said the keyboard is restricted (CarPlay's limited user interfaces).
    public var keyboardRestrictedByCar: Bool
    /// Ground speed in metres per second, or nil when no fresh reading exists.
    public var speedMetersPerSecond: Double?
    public var observedAt: Date

    public init(
        carPlayConnected: Bool,
        keyboardRestrictedByCar: Bool = false,
        speedMetersPerSecond: Double? = nil,
        observedAt: Date
    ) {
        self.carPlayConnected = carPlayConnected
        self.keyboardRestrictedByCar = keyboardRestrictedByCar
        self.speedMetersPerSecond = speedMetersPerSecond
        self.observedAt = observedAt
    }
}

/// Turns car signals into a driving mode with hysteresis, so a red light never flickers the keyboard.
public struct SparkDrivingStateReducer: Equatable, Sendable {
    /// Above this the car is moving. About 5 km/h, so a creeping queue still counts as driving.
    public static let movingThreshold = 1.4
    /// Below this the car may be stopped; between the two thresholds the previous answer holds.
    public static let stoppedThreshold = 0.6
    /// How long the car must be still before typing comes back.
    public static let parkedHold: TimeInterval = 6
    /// A speed reading older than this says nothing about now.
    public static let speedFreshness: TimeInterval = 20

    public private(set) var mode: SparkDrivingMode = .notDriving
    private var stillSince: Date?
    private var lastSpeedAt: Date?
    private var restrictedByCar = false

    public init() {}

    /// Apply one observation and return the mode it leads to.
    @discardableResult
    public mutating func apply(_ signals: SparkDrivingSignals) -> SparkDrivingMode {
        guard signals.carPlayConnected else {
            mode = .notDriving
            stillSince = nil
            lastSpeedAt = nil
            restrictedByCar = false
            return mode
        }
        let restrictionReleased = restrictedByCar && !signals.keyboardRestrictedByCar
        restrictedByCar = signals.keyboardRestrictedByCar
        if signals.keyboardRestrictedByCar {
            mode = .moving
            stillSince = nil
            return mode
        }
        if let speed = signals.speedMetersPerSecond {
            lastSpeedAt = signals.observedAt
            if speed >= Self.movingThreshold {
                mode = .moving
                stillSince = nil
                return mode
            }
            if speed <= Self.stoppedThreshold {
                let since = stillSince ?? signals.observedAt
                stillSince = since
                if mode == .moving,
                    signals.observedAt.timeIntervalSince(since) < Self.parkedHold
                {
                    return mode
                }
                mode = .parked
                return mode
            }
            stillSince = nil
            // Between the thresholds the last decision stands; a rolling stop is still a stop.
            if mode == .notDriving { mode = .parked }
            return mode
        }
        if restrictionReleased, lastSpeedAt == nil {
            mode = .parked
            return mode
        }
        // Connected with no speed at all: a stale or absent reading never traps the owner.
        if let lastSpeedAt,
            signals.observedAt.timeIntervalSince(lastSpeedAt) <= Self.speedFreshness
        {
            return mode
        }
        if mode == .notDriving { mode = .parked }
        return mode
    }
}

/// The copy the phone shows when typing is paused or allowed, shared by chat and the terminal.
public enum SparkDrivingCopy {
    public static var movingTitle: String { String(localized: "Voice only while driving") }
    public static var movingDetail: String {
        String(localized: "Typing pauses while the car is moving. Talk to your Spark instead.")
    }
    public static var parkedTitle: String { String(localized: "Typing is available") }
    public static var parkedDetail: String {
        String(localized: "The car allows typing. You can also keep using voice.")
    }
}
