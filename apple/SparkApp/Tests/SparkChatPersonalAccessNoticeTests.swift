import Foundation
import Testing

@testable import SparkAppComposition

/// QA-19: the denial told the owner to visit system settings and gave them no way there.
@Suite struct SparkChatPersonalAccessNoticeTests {
    @Test @MainActor func aDeniedCalendarOffersTheWayToSystemSettings() throws {
        let message = try #require(SparkPersonalError.denied.errorDescription)
        let notice = SparkChatPersonalContextCopy.accessNotice(
            message: message,
            canOpenSettings: true
        )
        #expect(notice.message == message)
        #expect(notice.actionTitle == "Open Settings")
        #expect(SparkChatPersonalContextCopy.settingsURL != nil)
    }

    @Test @MainActor func aFailureSettingsCannotFixIsNotSentThere() {
        let notice = SparkChatPersonalContextCopy.accessNotice(
            message: "Your calendar and reminders could not be read on this device.",
            canOpenSettings: false
        )
        #expect(notice.actionTitle == nil)
    }

    @Test @MainActor func onlyARefusalIsMarkedAsSomethingSettingsCanUndo() async {
        let store = PersonalContextTestStore()
        store.failure = .denied
        let model = SparkChatPersonalContextModel()
        model.store = store
        await model.include(.event)
        #expect(model.accessError == SparkPersonalError.denied.errorDescription)
        #expect(model.accessDenied)

        store.failure = .noCalendar
        let other = SparkChatPersonalContextModel()
        other.store = store
        await other.include(.event)
        #expect(other.accessError == SparkPersonalError.noCalendar.errorDescription)
        #expect(!other.accessDenied)
    }

    @Test @MainActor func grantedAccessClearsTheRefusalAndItsButton() async {
        let store = PersonalContextTestStore()
        store.failure = .denied
        let model = SparkChatPersonalContextModel()
        model.store = store
        await model.include(.event)
        #expect(model.accessDenied)
        store.failure = nil
        await model.include(.event)
        #expect(model.accessError == nil)
        #expect(!model.accessDenied)
    }
}
