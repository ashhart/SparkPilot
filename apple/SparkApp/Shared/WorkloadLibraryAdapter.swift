import Foundation
import SparkLibrary

/// Builds comparisons from library snapshots evaluated at one timestamp without probing Sparks or duplicating the cache.
enum WorkloadLibraryAdapter {
    @MainActor
    static func snapshot(
        from library: SparkLibrary,
        at date: Date
    ) -> WorkloadComparisonSnapshot {
        let operationalSnapshots = library.entries.compactMap { entry in
            library.operationalSnapshot(for: entry.id, at: date)
        }
        return WorkloadComparisonBuilder.snapshot(
            from: operationalSnapshots,
            generatedAt: date
        )
    }
}
