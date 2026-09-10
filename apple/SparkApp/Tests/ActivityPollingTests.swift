import Foundation
import SparkLibrary
import Testing
@testable import SparkAppComposition

private actor ActivityPollingProvider: CrossTargetModelLibraryDataProviding {
    private var calls = 0
    func count() -> Int { calls }
    private func increment() { calls += 1 }
    @MainActor func fetchSnapshot() async throws -> CrossTargetModelLibrarySnapshot {
        await increment()
        return .empty
    }
}

@MainActor
@Test func activityRefreshesRepeatedlyAndStopsWhenItsViewTaskIsCancelled() async throws {
    let provider = ActivityPollingProvider()
    let task = Task {
        await OperationalSurfaceRefresh.runUntilCancelled(
            modelLibrary: CrossTargetModelLibraryModel(provider: provider),
            library: SparkLibrary(store: MemoryLibraryStore()),
            workloads: WorkloadComparisonModel(snapshot: .empty),
            interval: .milliseconds(1)
        )
    }
    defer { task.cancel() }
    for _ in 0..<200 {
        if await provider.count() >= 3 { break }
        try await Task.sleep(for: .milliseconds(1))
    }
    #expect(await provider.count() >= 3)
    task.cancel()
    await task.value
    let calls = await provider.count()
    try await Task.sleep(for: .milliseconds(5))
    #expect(await provider.count() == calls)
}
