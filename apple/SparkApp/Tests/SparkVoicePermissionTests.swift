import Testing

@testable import SparkAppComposition

/// The owner asked to "say please enable the microphone", and no state may be a dead end.
struct SparkVoicePermissionTests {
    @Test func aGrantedPermissionShowsNoNotice() {
        #expect(SparkVoicePermissionPresentation.notice(for: .granted) == nil)
    }

    @Test func anUndecidedPermissionAsksRatherThanSendingTheOwnerToSettings() {
        let notice = SparkVoicePermissionPresentation.notice(for: .notDetermined)
        #expect(notice?.opensSettings == false)
        #expect(notice?.actionTitle == "Allow microphone access")
        #expect(notice?.message.contains("only while you are talking") == true)
    }

    @Test func aDeniedMicrophoneUsesTheOwnersWordsAndOpensSettings() {
        let notice = SparkVoicePermissionPresentation.notice(for: .microphoneDenied)
        #expect(notice?.title == "Please enable the microphone for SparkPilot")
        #expect(notice?.opensSettings == true)
        #expect(notice?.actionTitle == "Open Settings")
    }

    @Test func aDeniedSpeechRecogniserNamesSpeechRecognitionAndOpensSettings() {
        let notice = SparkVoicePermissionPresentation.notice(for: .speechDenied)
        #expect(notice?.title == "Please enable speech recognition for SparkPilot")
        #expect(notice?.opensSettings == true)
    }

    @Test func aRestrictedDeviceExplainsItselfWithoutPromisingSettingsWillHelp() {
        let notice = SparkVoicePermissionPresentation.notice(for: .speechRestricted)
        #expect(notice?.opensSettings == false)
        #expect(notice?.actionTitle == nil)
        #expect(notice?.message.isEmpty == false)
    }

    @Test func anUnavailableRecogniserOffersDictationRatherThanADeadEnd() {
        let notice = SparkVoicePermissionPresentation.notice(for: .speechUnavailable)
        #expect(notice?.opensSettings == false)
        #expect(notice?.message.isEmpty == false)
        #expect(notice?.title.isEmpty == false)
    }

    @Test func everyStateThatIsNotGrantedSaysSomethingAndWhatTheMicrophoneIsFor() {
        let states: [SparkVoicePermission] = [
            .notDetermined, .microphoneDenied, .speechDenied, .speechRestricted, .speechUnavailable,
        ]
        for state in states {
            let notice = SparkVoicePermissionPresentation.notice(for: state)
            #expect(notice != nil, "\(state) has no notice")
            #expect(notice?.title.isEmpty == false)
            #expect(notice?.message.isEmpty == false)
        }
        #expect(
            SparkVoicePermissionPresentation.purpose
                == "The microphone is used only while you are talking to your Spark."
        )
    }

    @Test func settingsIsReachableOnThisPlatform() {
        #expect(SparkVoicePermissionPresentation.settingsURL != nil)
    }
}
