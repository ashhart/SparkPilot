import Foundation
import SparkAPI
import SparkCore
import SparkDesignSystem
import SparkLibrary
import SwiftUI

func sparkDashboardPowerTelemetryDetail(_ powerLimitWatts: Double?) -> String {
    guard let limit = powerLimitWatts else {
        return String(localized: "Driver power reading")
    }
    return String(
        localized: .configuredPowerLimit(
            Measurement(value: limit, unit: UnitPower.watts)
                .formatted(
                    .measurement(
                        width: .abbreviated,
                        numberFormatStyle: .number.precision(.fractionLength(0))
                    )
                )
        )
    )
}
