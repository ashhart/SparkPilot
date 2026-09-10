import FoundationModels
import Foundation
import Testing

@testable import SparkLanguageModel

/// The app must say why Apple Intelligence is unusable rather than fall silent or claim a Spark is at fault.
@Suite struct AppleIntelligenceAvailabilityTests {
    @Test func everyAvailabilityReasonBecomesOneOwnerFacingState() {
        #expect(SparkAppleIntelligence.state(of: .available) == .ready)
        #expect(
            SparkAppleIntelligence.state(of: .unavailable(.deviceNotEligible)) == .deviceNotEligible
        )
        #expect(
            SparkAppleIntelligence.state(of: .unavailable(.appleIntelligenceNotEnabled))
                == .turnedOff
        )
        #expect(SparkAppleIntelligence.state(of: .unavailable(.modelNotReady)) == .modelDownloading)
    }

    @Test func everyStateExplainsItselfWithoutBlamingTheSpark() {
        for state in SparkAppleIntelligenceState.allCases {
            let explanation = state.explanation
            #expect(!explanation.isEmpty)
            #expect(explanation.contains(" "))
            #expect(!explanation.lowercased().contains("spark is"))
        }
    }

    /// Only Apple's own answer decides this; the app never infers it from a device model or an OS version.
    @Test func theProbeReadsApplesOwnAvailability() {
        #expect(
            SparkAppleIntelligence.state
                == SparkAppleIntelligence.state(of: SystemLanguageModel.default.availability)
        )
    }

    /// Chat and the intents run on the Spark; Apple's on-device model is never asked to answer.
    @Test func theAppNeverGeneratesWithApplesOnDeviceModel() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/SparkLanguageModel")
        let contents = try FileManager.default.contentsOfDirectory(
            at: sources,
            includingPropertiesForKeys: nil
        )
        for file in contents where file.pathExtension == "swift" {
            let source = try String(contentsOf: file, encoding: .utf8)
            #expect(
                !source.contains("LanguageModelSession("),
                "\(file.lastPathComponent) starts an on-device session; the Spark is the runtime"
            )
        }
    }
}
