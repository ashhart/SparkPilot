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
struct SparkDashboardLiveUpdater {
    let delay: @Sendable (Duration) async throws -> Void
    private var conservingPower: Bool {
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return true }
        #if os(iOS)
            UIDevice.current.isBatteryMonitoringEnabled = true
            return UIDevice.current.batteryState == .unplugged
        #elseif os(macOS)
            guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
                let source = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue()
            else { return false }
            return source as String == kIOPSBatteryPowerValue
        #else
            return false
        #endif
    }

    func run(
        interval: Duration,
        refresh: () async -> Void,
        refreshTelemetry: () async -> Void,
        refreshHistory: () async -> Void
    ) async {
        await refresh()
        while !Task.isCancelled {
            do {
                try await delay(
                    SparkDashboardModel.pollingInterval(interval, conservingPower: conservingPower)
                )
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await refreshTelemetry()
            // Let history enforce its own success and failure throttle independently of the one-second live loop.
            await refreshHistory()
        }
    }
}
