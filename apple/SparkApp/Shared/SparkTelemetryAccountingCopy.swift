import Foundation

/// Labels exact and estimated telemetry beside each value; docs/operations/telemetry-accounting.md records the detailed accounting.
public enum SparkTelemetryAccountingCopy {
    /// A counter the engine reports as a running total.
    public static var engineCumulative: String {
        String(
            localized: """
                Exact, as this engine reports it. Counting restarts when the \
                engine does.
                """
        )
    }

    /// SparkPilot's own daily usage, which is exact and narrower than a total.
    public static var sparkPilotDaily: String {
        String(
            localized: """
                Exact for requests SparkPilot handled that finished and \
                reported usage, while diagnostics were on. Other requests are \
                not counted.
                """
        )
    }

    /// Anything divided by an interval, or averaged over a window.
    public static var derivedEstimate: String {
        String(localized: "An estimate, worked out from readings taken moments apart.")
    }

    /// A one-minute history bucket, with how many samples it folded.
    public static func minuteBucket(sampleCount: Int) -> String {
        String(localized: .historyMinuteBucket(sampleCount))
    }

    /// A raw ten-second reading.
    public static var rawSample: String {
        String(localized: "One reading, taken by the Spark itself.")
    }

    /// Shown wherever a value is absent, so it is never rendered as zero.
    public static var unavailable: String {
        String(localized: "This Spark does not report this value.")
    }

    /// The dashboard's help control.
    public static var help: String {
        String(
            localized: """
                Some numbers here are counted and some are worked out. Engine \
                totals are exact but start again when the engine restarts. \
                SparkPilot's daily usage is exact for the requests it handled \
                that finished and reported usage while diagnostics were on, so \
                it is a floor rather than a total. Rates, latencies and \
                one-minute history points are estimates. Anything this Spark \
                does not report is shown as unavailable, never as zero.
                """
        )
    }
}
