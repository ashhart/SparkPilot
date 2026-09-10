import Foundation
import SparkAPI
import SwiftUI

enum SparkInferenceExperiencePresentation {
    static func activeRequests(_ value: Int?) -> String {
        guard let value else { return String(localized: "Not reported") }
        return String(localized: .requestsActive(value))
    }

    static func queuedRequests(_ value: Int?) -> String {
        guard let value else { return String(localized: "Not reported") }
        return String(localized: .requestsQueued(value))
    }

    static func count(_ value: Int64?) -> String {
        value?.formatted() ?? String(localized: "Not reported")
    }

    static func rate(_ value: Double?) -> String {
        guard let value else { return String(localized: "Not reported") }
        return String(
            localized: .requestsPerMinute(value.formatted(.number.precision(.fractionLength(1))))
        )
    }

    static func throughput(_ value: Double?) -> String {
        guard let value else { return String(localized: "Not reported") }
        return String(
            localized: .tokensPerSecond(value.formatted(.number.precision(.fractionLength(1))))
        )
    }

    static func latency(_ value: Double?) -> String {
        guard let value else { return String(localized: "Not reported") }
        return value < 1_000
            ? Measurement(value: value, unit: UnitDuration.milliseconds)
                .formatted(
                    .measurement(
                        width: .abbreviated,
                        numberFormatStyle: .number.precision(.fractionLength(0))
                    )
                )
            : Measurement(value: value / 1_000, unit: UnitDuration.seconds)
                .formatted(
                    .measurement(
                        width: .abbreviated,
                        numberFormatStyle: .number.precision(.fractionLength(2))
                    )
                )
    }

    static func uptime(_ seconds: Int64?) -> String {
        guard let seconds else { return String(localized: "Not reported") }
        return SparkDuration.coarse(seconds: seconds)
    }

    /// One plain-language answer to "is inference working, and why is it slow", from the same sample as the counters.
    static func verdict(_ sample: SparkInferenceExperienceSample) -> String {
        let state = sample.state?.lowercased() ?? ""
        if ["loading", "starting", "draining", "stopping"].contains(state) {
            return String(localized: "The model is loading; answers start when it is ready.")
        }
        if ["failed", "error", "stopped", "unloaded"].contains(state) {
            return String(localized: "Inference is not running; start a model to answer requests.")
        }
        if let pressure = sample.memoryPressure?.lowercased(), !pressure.isEmpty,
            pressure != "normal"
        {
            return String(
                localized:
                    "Memory is under pressure; answers may slow down or stop until it clears."
            )
        }
        let active = sample.activeRequests ?? 0
        let queued = sample.queueDepth ?? 0
        if queued > 0 {
            return String(
                localized: .servingBusy(active: active, queued: queued)
            )
        }
        if active > 0 {
            if let rate = sample.tokensPerSecond, rate > 0 {
                let tokens = rate.formatted(.number.precision(.fractionLength(0)))
                return String(localized: .servingAnswering(active: active, tokensPerSecond: tokens))
            }
            return String(localized: .servingAnswering(active: active))
        }
        if sample.modelID != nil {
            return String(localized: "Idle and ready; the next request answers immediately.")
        }
        return String(localized: "No model is serving right now.")
    }

    /// Humanise an engine state this build does not know; every known state has localised copy above.
    static func state(_ state: String?) -> String {
        guard let state, !state.isEmpty else { return String(localized: "State not reported") }
        return state.replacingOccurrences(of: "_", with: " ").localizedCapitalized
    }

    static func sourceLabel(
        availability: String?,
        ageSeconds: Int64?,
        transportIsLive: Bool
    ) -> String {
        switch availability {
        case "live": return String(localized: "Live")
        case "cached":
            return ageSeconds.map {
                String(localized: .cachedForAge(SparkDuration.brief(seconds: $0)))
            } ?? String(localized: "Cached")
        case "unavailable", "unsupported": return String(localized: "Metrics unavailable")
        default: return transportIsLive ? String(localized: "Live") : String(localized: "Saved")
        }
    }
}

/// Describes each trend's current value, range and measurement count for accessibility.
enum SparkTrendAccessibility {
    static func summary(_ values: [Double]) -> LocalizedStringResource {
        guard let latest = values.last,
            let lowest = values.min(),
            let highest = values.max()
        else {
            return .locallySavedSamples(0)
        }
        return .trendSummary(
            latest: format(latest),
            lowest: format(lowest),
            highest: format(highest),
            samples: values.count
        )
    }

    /// Use the reader's locale when formatting spoken numeric values.
    private static func format(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)))
    }
}
