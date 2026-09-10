import Foundation

/// QA-12, QA-25: "no Spark is paired" and "no paired Spark this device can use" are different problems with different next steps, and the empty states used to say the first for both.
public enum SparkAccessGate: Equatable, Sendable {
    /// Nothing is in the library; the next step is pairing.
    case noSparkSaved
    /// Sparks are saved but none of them yields a usable session here; the next step is opening one.
    case noUsableSpark
    /// At least one Spark this screen can work with.
    case ready

    public static func resolve(savedSparks: Int, usableTargets: Int) -> SparkAccessGate {
        if usableTargets > 0 { return .ready }
        return savedSparks == 0 ? .noSparkSaved : .noUsableSpark
    }
}
