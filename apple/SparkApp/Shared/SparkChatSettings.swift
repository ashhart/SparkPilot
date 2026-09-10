import Foundation
import Observation

/// Chat preferences that belong to this device rather than to a Spark.
@MainActor
@Observable
public final class SparkChatSettings {
    public static let shared = SparkChatSettings()

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private static let plainStyleKey = "chat.plainStyle"

    public var isPlainStyleEnabled: Bool {
        didSet { defaults.set(isPlainStyleEnabled, forKey: Self.plainStyleKey) }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Absent means never chosen, which is on, so the default survives a reinstall honestly.
        isPlainStyleEnabled =
            defaults.object(forKey: Self.plainStyleKey) as? Bool ?? true
    }

    public static let plainStyleTitle = String(localized: "Plain style (no em dashes, no filler)")
    public static let plainStyleExplanation = String(
        localized:
            "Asks for plain, direct answers and removes em dashes and filler openings from replies."
    )
}
