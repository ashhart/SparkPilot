import Testing
@testable import SparkAppComposition

@MainActor
struct SparkVoicePrivacyTests {
    @Test func unsupportedLocalRecognitionCannotCreateACloudCapableRequest() {
        #expect(throws: SparkVoiceCapture.Failure.recognitionUnavailable) {
            _ = try SparkVoiceCapture.recognitionRequest(supportsOnDevice: false)
        }
    }
    @Test func supportedRecognitionCannotFallBackToAppleServers() throws {
        let request = try SparkVoiceCapture.recognitionRequest(supportsOnDevice: true)
        #expect(request.requiresOnDeviceRecognition)
    }
}
