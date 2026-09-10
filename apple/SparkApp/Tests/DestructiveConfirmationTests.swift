import Foundation
import Testing

@testable import SparkAppComposition

private func sharedSource(_ name: String) throws -> String {
    let testFile = URL(fileURLWithPath: #filePath)
    let appRoot = testFile.deletingLastPathComponent().deletingLastPathComponent()
    return try String(contentsOf: appRoot.appending(path: "Shared/\(name).swift"), encoding: .utf8)
}

/// QA-15: a confirmation needs a stated way back, and it must be an alert, because iOS 26 shows a row-anchored confirmation dialog as a popover that drops the cancel button it is given.
@Test func everyConfirmationThisRoundOwnsOffersAnExplicitCancel() throws {
    let files = [
        "SparkPersonalInputViews", "SparkInferenceRunHistoryView", "SparkRequestHistoryView",
        "SparkHouseholdView", "SparkBugFeedbackView", "RemoteAccessSettingsView",
        "SharedAccessView", "DeviceManagementView", "SparkPowerControls", "SparkSettingsView",
        "SparkLibraryView", "SparkDashboardView", "ProviderCredentials", "SparkWarmupView",
        "SparkAutomationsView", "SparkChatExecutionPrompts", "SparkIntentActionView",
        "FleetView", "SparkIdentitySettings", "SparkQualificationView", "InviteDeviceView",
        "SparkPersonalReviewView",
    ]

    for file in files {
        let source = try sharedSource(file)
        #expect(
            !source.contains(".confirmationDialog("),
            "\(file) still uses a confirmation dialog, whose popover form hides the cancel button"
        )
        let alerts = source.components(separatedBy: ".alert(").dropFirst()
        #expect(!alerts.isEmpty, "\(file) lost the confirmation this defect is about")
        for alert in alerts {
            #expect(
                alert.contains("role: .cancel"),
                "\(file) has a confirmation with no cancel role"
            )
        }
    }
}

/// QA-17: "Run a Shortcut" put a tall editor between the name field and the button with no label, placeholder or hint on screen.
@Test func theShortcutTextEditorIsLabelledOnScreen() throws {
    let source = try sharedSource("SparkPersonalInputViews")

    #expect(source.contains("accessibilityLabel(\"Text passed to Shortcuts\")"))
    #expect(
        source.contains("Text(\"Text passed to Shortcuts\")"),
        "the editor needs a visible label, not only an accessibility one"
    )
}
