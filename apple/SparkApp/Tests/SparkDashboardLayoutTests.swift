import Testing

@testable import SparkAppComposition

@Test func atAGlanceDefaultsStayCompact() {
    #expect(
        SparkDashboardMetricSelection.defaults == [
            .gpu,
            .temperature,
            .unifiedMemory,
            .inference,
        ]
    )
}

@Test func atAGlanceSelectionRoundTripsInStableOrder() {
    let selection = SparkDashboardMetricSelection(
        encoded: "uptime,gpu,storage,gpu,unknown"
    )

    #expect(selection.metrics == [.gpu, .storage, .uptime])
    #expect(selection.encoded == "gpu,storage,uptime")
}

@Test func atAGlanceSelectionCannotBecomeEmptyOrOverloaded() {
    #expect(
        SparkDashboardMetricSelection(encoded: "").metrics
            == SparkDashboardMetricSelection.defaults
    )

    let allMetrics = SparkDashboardMetric.allCases.map(\.rawValue).joined(separator: ",")
    #expect(SparkDashboardMetricSelection(encoded: allMetrics).metrics.count == 6)
}

@Test func atAGlancePreferencesAreScopedToOneSpark() {
    #expect(
        SparkDashboardMetricSelection.storageKey(targetID: "spark-one")
            != SparkDashboardMetricSelection.storageKey(targetID: "spark-two")
    )
}
