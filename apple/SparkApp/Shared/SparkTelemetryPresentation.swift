import Foundation
import SparkAPI

/// Formats partial telemetry with Waiting for expected readings and Unavailable for values the Spark does not report.
enum SparkTelemetryPresentation {
    static func cpu(_ telemetry: TelemetrySnapshot?) -> String {
        guard let telemetry else { return String(localized: "Waiting") }
        return percent(telemetry.system.cpuUtilisation)
    }

    /// "this Spark does not report it at all", said once.
    private static var unavailable: String { String(localized: "Unavailable") }

    /// Uses the reader's locale for decimal separators and digit grouping.
    private static func percent(_ fraction: Double) -> String {
        fraction.formatted(.percent.precision(.fractionLength(0)))
    }

    private static func decimal(_ value: Double, places: Int) -> String {
        value.formatted(.number.precision(.fractionLength(places)))
    }

    static func cpuDetail(_ telemetry: TelemetrySnapshot?) -> String {
        guard let load = telemetry?.system.loadAverage1m else {
            return String(localized: "Processor load is not reported yet.")
        }
        return String(localized: .loadAverage(decimal(load, places: 2)))
    }

    static func gpu(_ telemetry: TelemetrySnapshot?) -> String {
        guard let utilisation = telemetry?.accelerator.utilisation else { return unavailable }
        return percent(utilisation)
    }

    static func highestTemperature(_ telemetry: TelemetrySnapshot?) -> Double? {
        [telemetry?.accelerator.temperatureCelsius, telemetry?.system.temperatureCelsius]
            .compactMap { $0 }.filter { $0.isFinite }.max()
    }

    static func temperature(_ telemetry: TelemetrySnapshot?) -> String {
        guard let value = highestTemperature(telemetry) else { return unavailable }
        return Measurement(value: value, unit: UnitTemperature.celsius)
            .formatted(.measurement(width: .narrow, usage: .weather))
    }

    static func temperatureSeverity(_ celsius: Double?) -> Int {
        guard let celsius, celsius.isFinite else { return 0 }
        if celsius >= 90 { return 3 }
        if celsius >= 84 { return 2 }
        return celsius >= 75 ? 1 : 0
    }

    static func temperatureDetail(_ telemetry: TelemetrySnapshot?) -> String {
        guard let value = highestTemperature(telemetry) else { return unavailable }
        switch temperatureSeverity(value) {
        case 3:
            return String(localized: "Critical temperature; check cooling and reduce the workload.")
        case 2: return String(localized: "High temperature; check that the vents are clear.")
        case 1: return String(localized: "The Spark is warm.")
        default: return String(localized: "Highest reported temperature")
        }
    }

    static func power(_ telemetry: TelemetrySnapshot?) -> String {
        guard let watts = telemetry?.accelerator.powerDrawWatts else { return unavailable }
        return Measurement(value: watts, unit: UnitPower.watts)
            .formatted(
                .measurement(
                    width: .abbreviated,
                    numberFormatStyle: .number.precision(.fractionLength(0))
                )
            )
    }

    static func unifiedMemory(_ telemetry: TelemetrySnapshot?) -> String {
        guard let memory = telemetry?.system, memory.unifiedMemoryTotalBytes > 0 else {
            return unavailable
        }
        return String(
            localized: .memoryUsed(
                FleetFormat.gigabytes(memory.unifiedMemoryUsedBytes)
            )
        )
    }

    static func unifiedMemoryDetail(_ telemetry: TelemetrySnapshot?) -> String {
        guard let memory = telemetry?.system, memory.unifiedMemoryTotalBytes > 0 else {
            return String(localized: "Unified memory is not reported yet.")
        }
        let available = FleetFormat.gigabytes(memory.unifiedMemoryAvailableBytes)
        let pressure = memoryPressureWord(memory.memoryPressure)
        return String(
            localized: .memoryAvailableWithPressure(available: available, pressure: pressure)
        )
    }

    /// Describes the guard's memory-pressure level in owner-facing terms.
    static func memoryPressureWord(_ rung: String) -> String {
        switch rung.lowercased() {
        case "normal": String(localized: "Normal")
        case "warning": String(localized: "Elevated")
        case "critical": String(localized: "High")
        case "emergency": String(localized: "Very high")
        case "unknown", "": String(localized: "Unreported")
        default: rung.capitalized
        }
    }

    static func gpuMemory(_ telemetry: TelemetrySnapshot?) -> String {
        guard
            let memory = telemetry?.accelerator.memoryUsedBytes,
            let total = telemetry?.accelerator.memoryTotalBytes,
            total > 0
        else { return unavailable }
        return String(
            localized: .memoryUsed(
                ByteCountFormatter.string(fromByteCount: memory, countStyle: .memory)
            )
        )
    }

    static func gpuMemoryDetail(_ telemetry: TelemetrySnapshot?) -> String {
        guard
            let memory = telemetry?.accelerator.memoryUsedBytes,
            let total = telemetry?.accelerator.memoryTotalBytes,
            total > 0
        else { return String(localized: "Driver memory counters are not reported.") }
        return String(
            localized: .memoryOfTotal(
                used: ByteCountFormatter.string(fromByteCount: memory, countStyle: .memory),
                total: ByteCountFormatter.string(fromByteCount: total, countStyle: .memory)
            )
        )
    }

    static func memoryStall(_ telemetry: TelemetrySnapshot?) -> String {
        guard let average = telemetry?.system.memoryPSISomeAvg10 else { return unavailable }
        return (average / 100).formatted(.percent.precision(.fractionLength(2)))
    }

    /// Report partial and full stall availability separately when the kernel omits one reading.
    static func memoryStallDetail(_ telemetry: TelemetrySnapshot?) -> String {
        guard telemetry?.system.memoryPSISomeAvg10 != nil else {
            return String(localized: "Linux memory pressure stalls are not reported.")
        }
        guard let full = telemetry?.system.memoryPSIFullAvg10 else {
            return String(localized: .stallAverageWithoutFull)
        }
        return String(
            localized: .stallAverageWithFull(
                (full / 100).formatted(.percent.precision(.fractionLength(2)))
            )
        )
    }

    static func storage(_ telemetry: TelemetrySnapshot?) -> String {
        guard let storage = telemetry?.storage, storage.totalBytes > 0 else { return unavailable }
        return String(
            localized: .memoryUsed(
                ByteCountFormatter.string(fromByteCount: storage.usedBytes, countStyle: .file)
            )
        )
    }

    static func storageDetail(_ telemetry: TelemetrySnapshot?) -> String {
        guard let storage = telemetry?.storage, storage.totalBytes > 0 else {
            return String(localized: "Filesystem capacity is not reported yet.")
        }
        return String(
            localized: .storageFreeOfTotal(
                free: ByteCountFormatter.string(
                    fromByteCount: storage.freeBytes,
                    countStyle: .file
                ),
                total: ByteCountFormatter.string(
                    fromByteCount: storage.totalBytes,
                    countStyle: .file
                )
            )
        )
    }

    /// Show throughput only while serving; otherwise present the engine state.
    static func inference(_ telemetry: TelemetrySnapshot?) -> String {
        guard let inference = telemetry?.inference else { return String(localized: "Waiting") }
        if let tokens = inference.tokensPerSecond {
            return String(localized: .tokensPerSecond(decimal(tokens, places: 1)))
        }
        return inference.state.capitalized
    }

    static func inferenceDetail(_ telemetry: TelemetrySnapshot?) -> String {
        guard let inference = telemetry?.inference else {
            return String(localized: "Inference activity is not reported yet.")
        }
        guard let queueDepth = inference.queueDepth else {
            return String(
                localized: .requestsActiveQueueUnavailable(inference.activeRequests)
            )
        }
        return String(
            localized: .requestsActiveAndQueued(
                active: inference.activeRequests,
                queued: queueDepth
            )
        )
    }

    static func usage(_ telemetry: TelemetrySnapshot?) -> String {
        guard let usage = telemetry?.usage else { return String(localized: "Waiting") }
        return String(localized: .tokensUsed(usage.totalTokens))
    }

    static func usageDetail(_ telemetry: TelemetrySnapshot?) -> String {
        guard let usage = telemetry?.usage else {
            return String(localized: "Today's local request totals are not reported yet.")
        }
        // Keep uncounted failures distinct from an observed zero.
        if let failures = usage.failures, failures > 0 {
            return String(
                localized: .requestsTodayWithFailures(
                    requests: usage.requests,
                    failures: failures
                )
            )
        }
        return String(localized: .requestsToday(usage.requests))
    }

    /// Coarsen uptime to useful day/hour units.
    static func uptime(_ telemetry: TelemetrySnapshot?) -> String {
        guard let seconds = telemetry?.system.uptimeSeconds else {
            return String(localized: "Waiting")
        }
        return SparkDuration.coarse(seconds: Int64(seconds))
    }

    /// Maps known contract values to localised copy and omits unknown clauses instead of displaying raw server words.
    private static func memoryPressure(_ reported: String) -> String? {
        switch reported {
        case "normal": String(localized: "Normal")
        case "warning": String(localized: "Warning")
        case "critical": String(localized: "Critical")
        case "emergency": String(localized: "Emergency")
        default: nil
        }
    }
}
