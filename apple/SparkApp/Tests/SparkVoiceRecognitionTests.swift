import Foundation
import Testing

@testable import SparkAppComposition

private func voicePurposePlist(_ target: String) throws -> [String: Any] {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let contents = try Data(contentsOf: root.appending(path: "\(target)/Info.plist"))
    let parsed = try PropertyListSerialization.propertyList(from: contents, format: nil)
    return try #require(parsed as? [String: Any])
}

/// BH-20: the consent string promises this device, so a capture never quietly uses Apple's servers.
struct SparkVoiceRecognitionTests {
    @Test func withTheSettingOffSpeechIsTranscribedHereOrNotAtAll() {
        let unsupported = SparkVoiceRecognitionPolicy.mode(
            supportsOnDevice: false,
            allowsAppleServers: false
        )
        #expect(unsupported.requiresOnDeviceRecognition)
        #expect(!unsupported.isPermitted, "this device would have sent the audio to Apple")

        let supported = SparkVoiceRecognitionPolicy.mode(
            supportsOnDevice: true,
            allowsAppleServers: false
        )
        #expect(supported.requiresOnDeviceRecognition)
        #expect(supported.isPermitted)
    }

    @Test func allowingApplesServiceChangesOnlyTheDeviceThatCannotDoItAlone() {
        let unsupported = SparkVoiceRecognitionPolicy.mode(
            supportsOnDevice: false,
            allowsAppleServers: true
        )
        #expect(!unsupported.requiresOnDeviceRecognition)
        #expect(unsupported.isPermitted)

        let supported = SparkVoiceRecognitionPolicy.mode(
            supportsOnDevice: true,
            allowsAppleServers: true
        )
        #expect(supported.requiresOnDeviceRecognition, "a device that can do it alone still does")
        #expect(supported.isPermitted)
    }

    @Test func theSettingIsOffUntilTheOwnerTurnsItOn() throws {
        let suite = "spark.voice.recognition.tests"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        #expect(!SparkVoiceRecognitionPolicy.allowsAppleServers(in: defaults))
        SparkVoiceRecognitionPolicy.setAllowsAppleServers(true, in: defaults)
        #expect(SparkVoiceRecognitionPolicy.allowsAppleServers(in: defaults))
        defaults.removePersistentDomain(forName: suite)
    }

    @Test func theScreenNamesApplesServiceOnlyWhenTheOwnerHasAllowedIt() {
        let states: [SparkVoicePermission] = [
            .notDetermined, .microphoneDenied, .speechDenied, .speechRestricted, .speechUnavailable,
        ]
        for state in states {
            let closed = SparkVoicePermissionPresentation.notice(
                for: state,
                allowsAppleServers: false
            )
            #expect(
                closed?.message.contains("Apple") == false,
                "\(state) named a fallback the owner has not allowed"
            )
        }
        let promise = SparkVoicePermissionPresentation.recognitionPromise(allowsAppleServers: false)
        #expect(promise.contains("this device"))
        #expect(!promise.contains("Apple"))
        let allowed = SparkVoicePermissionPresentation.recognitionPromise(allowsAppleServers: true)
        #expect(allowed.contains("Apple"))
        let notice = SparkVoicePermissionPresentation.notice(
            for: .speechDenied,
            allowsAppleServers: true
        )
        #expect(notice?.message.contains("Apple") == true)
    }

    @Test(arguments: ["Shared", "macOS"])
    func theSpeechPurposeStringIsTrueInBothCases(target: String) throws {
        let plist = try voicePurposePlist(target)
        let speech = try #require(plist["NSSpeechRecognitionUsageDescription"] as? String)
        #expect(speech.contains("on this device"))
        #expect(speech.contains(SparkVoicePermissionPresentation.appleServiceSettingTitle))
        #expect(speech.contains("off"))
        #expect(!speech.contains("transcribes your speech on this device to send messages"))
    }
}
