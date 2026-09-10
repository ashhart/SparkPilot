import Foundation
#if os(iOS)
    import UIKit
#elseif os(macOS)
    import IOKit.ps
#endif
import Observation
import SparkAPI
import SparkCore
import SparkDesignSystem
import SparkLibrary
import SparkSecurity
import SwiftUI
import UniformTypeIdentifiers

@MainActor
public protocol SparkTelemetryCaching: AnyObject {
    func load(targetID: String) throws -> TelemetrySnapshot?
    func save(_ snapshot: TelemetrySnapshot, targetID: String) throws
}

/// Caches telemetry in device-local UserDefaults for display without iCloud synchronisation.
@MainActor
public final class UserDefaultsSparkTelemetryCache: SparkTelemetryCaching {
    private let defaults: UserDefaults
    private let keyPrefix: String

    public init(
        defaults: UserDefaults = .standard,
        keyPrefix: String = "sparkpilot.telemetry.v1."
    ) {
        self.defaults = defaults
        self.keyPrefix = keyPrefix
    }

    public func load(targetID: String) throws -> TelemetrySnapshot? {
        guard let data = defaults.data(forKey: keyPrefix + targetID) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(TelemetrySnapshot.self, from: data)
    }

    public func save(_ snapshot: TelemetrySnapshot, targetID: String) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        defaults.set(try encoder.encode(snapshot), forKey: keyPrefix + targetID)
    }
}
