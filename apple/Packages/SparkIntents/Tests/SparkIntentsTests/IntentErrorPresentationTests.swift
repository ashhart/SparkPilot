import AppIntents
import Foundation
import Testing

@testable import SparkIntents

/// Siri and Shortcuts read a thrown error through CustomLocalizedStringResourceConvertible; without it they show their own generic failure and the owner never sees this copy.
@Suite struct IntentErrorPresentationTests {
    private static let everyCase: [SparkIntentError] = [
        .noPairedSpark,
        .deviceRevoked,
        .offline,
        .targetRequired,
        .targetUnavailable,
        .permissionDenied,
        .actionRequiresApp("Review the change in SparkPilot."),
        .requestTooLarge(limitBytes: 8_192),
        .modelNotReady(modelID: "llama"),
        .modelNotInstalled(modelID: "llama"),
        .unsupportedFileType("image/heic"),
        .unsupportedFileType(nil),
        .fileHasNoText,
        .analysisContinuesOnSpark(jobID: "job"),
        .analysisNotFinished(jobID: "job"),
        .analysisJobUnknown(jobID: "job"),
        .analysisJobUnknown(jobID: ""),
        .analysisFailed(reason: "the engine stopped"),
        .analysisUnsupported,
    ]

    @Test func everyIntentErrorPresentsItsOwnerCopyToTheSystem() throws {
        for error in Self.everyCase {
            let thrown: any Error = error
            let convertible = try #require(
                thrown as? any CustomLocalizedStringResourceConvertible,
                "\(error) would reach Siri as a generic failure"
            )
            #expect(String(localized: convertible.localizedStringResource) == error.displayMessage)
            #expect(!error.displayMessage.isEmpty)
        }
    }

    /// A message that still reads like a key never made it through the catalogue.
    @Test func ownerCopyNeverLeaksACatalogueKey() {
        for error in Self.everyCase {
            #expect(!error.displayMessage.hasPrefix("intent."))
            #expect(error.displayMessage.contains(" "))
        }
    }
}
