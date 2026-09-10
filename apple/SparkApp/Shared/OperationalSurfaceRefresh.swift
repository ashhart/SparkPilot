import Foundation
import SparkLibrary

/// Projects one refreshed authenticated snapshot across wide surfaces while preserving Workloads interaction state.
@MainActor
public enum OperationalSurfaceRefresh {
    public static func runUntilCancelled(
        modelLibrary: CrossTargetModelLibraryModel,
        library: SparkLibrary,
        workloads: WorkloadComparisonModel,
        interval: Duration = .seconds(8)
    ) async {
        while !Task.isCancelled {
            await run(modelLibrary: modelLibrary, library: library, workloads: workloads)
            do { try await Task.sleep(for: interval) } catch { return }
        }
    }

    public static func run(
        modelLibrary: CrossTargetModelLibraryModel,
        library: SparkLibrary,
        workloads: WorkloadComparisonModel,
        at date: Date = Date()
    ) async {
        await modelLibrary.refresh()
        workloads.replaceSnapshot(
            WorkloadLibraryAdapter.snapshot(from: library, at: date)
        )
    }
}
