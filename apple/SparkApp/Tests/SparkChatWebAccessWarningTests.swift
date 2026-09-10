import Foundation
import SparkLibrary
import Testing

@testable import SparkAppComposition

/// Web access and shared personal context in one conversation earn a warning; either alone does not.
@MainActor
struct SparkChatWebAccessWarningTests {
    @Test func theWarningAppearsOnlyWhenWebAccessMeetsSharedContext() {
        let model = SparkChatModel(
            library: SparkLibrary(store: MemoryLibraryStore(), now: { Date() })
        )
        let access = SparkChatWebAccess()
        #expect(access.personalContextWarning(for: model) == nil)
        access.setOn(true, for: model)
        #expect(access.personalContextWarning(for: model) == nil)
        model.sharesPersonalContext = true
        let warning = access.personalContextWarning(for: model)
        #expect(warning?.contains("calendar") == true)
        access.setOn(false, for: model)
        #expect(access.personalContextWarning(for: model) == nil)
    }
}
