import SwiftUI

/// The §41.2 spacing scale. Views name a step instead of inventing a number.
public enum SparkSpacing {
    public static let tiny: CGFloat = 4
    public static let small: CGFloat = 8
    public static let compact: CGFloat = 12
    public static let regular: CGFloat = 16
    public static let large: CGFloat = 24
    public static let section: CGFloat = 32
    public static let page: CGFloat = 48

    /// The scale itself, so a test can assert that nothing drifts off it.
    public static let scale: [CGFloat] = [tiny, small, compact, regular, large, section, page]
}

/// The §41.2 card corner radii.
public enum SparkRadius {
    public static let compact: CGFloat = 18
    public static let standard: CGFloat = 24
    public static let hero: CGFloat = 30

    public static let scale: [CGFloat] = [compact, standard, hero]
}

/// The §41.2 layout constants that are not spacing.
public enum SparkLayout {
    /// The smallest hit target the plan allows.
    public static let minimumTouchTarget: CGFloat = 44
    /// Mac content width bounds. A reading column clamps into this range.
    public static let macContentWidthRange: ClosedRange<CGFloat> = 680...1100

    /// Clamp a requested Mac reading width into the plan's range.
    public static func macContentWidth(_ requested: CGFloat) -> CGFloat {
        min(max(requested, macContentWidthRange.lowerBound), macContentWidthRange.upperBound)
    }
}

/// The §41.2 motion budget: 0.2 s to 0.35 s, and nothing at all under Reduce Motion.
public enum SparkMotion {
    public static let quick: Double = 0.2
    public static let standard: Double = 0.25
    public static let deliberate: Double = 0.35

    public static let range: ClosedRange<Double> = quick...deliberate

    /// The animation for a metric or state change, or `nil` when motion is reduced.
    public static func metricChange(reduceMotion: Bool, duration: Double = standard) -> Animation? {
        guard !reduceMotion else { return nil }
        return .easeInOut(duration: min(max(duration, quick), deliberate))
    }
}

/// One place to speak a fraction as a locale-formatted percentage (§51.1, §51.2).
public enum SparkPercent {
    /// Floor rather than round, so progress is never overstated (§62.3's no fake progress).
    public static func string(_ fraction: Double) -> String {
        let floored = (min(1, max(0, fraction)) * 100).rounded(.down) / 100
        return floored.formatted(.percent.precision(.fractionLength(0)))
    }

    public static func text(_ fraction: Double) -> Text {
        Text(verbatim: string(fraction))
    }
}
