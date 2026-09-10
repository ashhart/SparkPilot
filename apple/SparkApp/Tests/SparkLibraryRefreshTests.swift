import Foundation
import SparkLibrary
import Testing

@testable import SparkAppComposition

/// The phone Home refreshes every saved Spark on pull, through the owner model's own re-probe.
@MainActor
struct SparkLibraryRefreshTests {
    @Test func thePhoneHomeCarriesAPullToRefreshAction() async {
        var refreshed = 0
        let view = SparkLibraryView(
            library: SparkLibrary(store: MemoryLibraryStore(), now: { Date() }),
            onAddSpark: {},
            onOpen: { _ in },
            onRemove: { _ in },
            onRetryStorage: {},
            onRefresh: { refreshed += 1 }
        )
        await view.onRefresh?()
        #expect(refreshed == 1)
    }
}
