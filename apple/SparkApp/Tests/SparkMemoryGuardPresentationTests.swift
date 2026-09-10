import Testing

@testable import SparkAppComposition

/// Memory-guard labels must show the configured numeric threshold rather than literal interpolation syntax.

@Test func eachThresholdLabelShowsItsValue() {
    #expect(
        SparkMemoryGuardPresentation.label(.warning, gibFree: 16) == "Warning at 16 GiB free"
    )
    #expect(
        SparkMemoryGuardPresentation.label(.critical, gibFree: 10) == "Critical at 10 GiB free"
    )
    #expect(
        SparkMemoryGuardPresentation.label(.emergency, gibFree: 6) == "Emergency at 6 GiB free"
    )
}

/// Reject unresolved interpolation syntax in rendered threshold labels.
@Test func aLabelNeverContainsTheExpressionItShouldHaveInterpolated() {
    let rungs: [SparkMemoryGuardPresentation.Rung] = [.warning, .critical, .emergency]
    for rung in rungs {
        let label = SparkMemoryGuardPresentation.label(rung, gibFree: 12)
        #expect(!label.contains("model."))
        #expect(!label.contains("GiB)"))
        #expect(label.contains("12"), "\(label) does not show the threshold it is setting")
    }
}

/// Update threshold labels at every selectable memory-guard step.
@Test func everyStepInTheRangeReadsDifferently() {
    let labels = (3...64).map { SparkMemoryGuardPresentation.label(.warning, gibFree: $0) }
    #expect(Set(labels).count == labels.count)
}
