import Foundation
import Testing

@testable import SparkAPI

/// Keep decoder and response diagnostics out of every user-visible failure presentation.
@Suite
struct APIFailurePresentationTests {

    /// Retain exact decoder diagnostics without displaying their raw prose.
    private func decodeFailure() -> APIError {
        struct Expected: Decodable { let modelId: String }
        var raw = ""
        do {
            _ = try JSONDecoder().decode(Expected.self, from: Data(#"{"nope": 1}"#.utf8))
        } catch {
            raw = "decode failed: \(error)"
        }
        return APIError(.malformedResponse, statusCode: 200, diagnosticDetail: raw)
    }

    @Test
    func aDecoderDescriptionNeverReachesTheReader() {
        let error = decodeFailure()
        let shown = APIError.message(for: error)
        #expect(!error.diagnosticDetail.isEmpty)
        #expect(!shown.contains("decode failed"))
        #expect(!shown.contains("keyNotFound"))
        #expect(!shown.contains("CodingKeys"))
        #expect(!shown.contains(error.diagnosticDetail))
        #expect(shown == String(localized: .sparkAnswerUnreadable))
    }

    @Test
    func theSameLeakIsClosedThroughLocalizedDescription() {
        // Apply the same redaction boundary to localizedDescription.
        let error = decodeFailure()
        #expect(!error.localizedDescription.contains("decode failed"))
        #expect(error.localizedDescription == APIError.message(for: error))
    }

    @Test
    func serverProseIsKeptOutOfCopyAndTheCodeIsWhatIsShown() {
        let prose = "runtime: catalogue lock held by pid 4213 at /var/lib/spark-runtime/state.db"
        let error = APIError(
            .reported,
            statusCode: 409,
            code: "CATALOGUE_LOCKED",
            diagnosticDetail: prose
        )
        let shown = APIError.message(for: error)
        #expect(!shown.contains(prose))
        #expect(!shown.contains("/var/lib"))
        #expect(!shown.contains("pid"))
        #expect(shown.contains("CATALOGUE_LOCKED"))
        #expect(error.diagnosticDetail == prose)
    }

    @Test
    func aRefusedPairingNeverQuotesTheBodyItWasRefusedWith() {
        // Never display an unauthenticated pairing response body.
        let body = Data(#"{"error":{"message":"token sk-live-4f3a is invalid"}}"#.utf8)
        let shown = APIError.message(
            for: APIError(
                PairingClient.failure(status: 401),
                statusCode: 401,
                diagnosticDetail: PairingClient.diagnostic(body: body)
            )
        )
        #expect(!shown.contains("sk-live-4f3a"))
        #expect(!shown.contains("token"))
        #expect(shown == String(localized: .invitationRefused))
    }

    @Test
    func eachPairingStatusIsItsOwnReasonRatherThanAStatusInASentence() {
        #expect(PairingClient.failure(status: 401) == .invitationRefused)
        #expect(PairingClient.failure(status: 403) == .invitationRefused)
        #expect(PairingClient.failure(status: 404) == .invitationUnknown)
        #expect(PairingClient.failure(status: 409) == .invitationAlreadyUsed)
        #expect(PairingClient.failure(status: 410) == .invitationExpired)
        #expect(PairingClient.failure(status: 500) == .unexpectedStatus)
    }

    @Test
    func theBoundedDiagnosticIsBoundedRatherThanTheWholeBody() {
        let body = Data(String(repeating: "a", count: 8_000).utf8)
        #expect(PairingClient.diagnostic(body: body).count == 1_000)
    }

    @Test
    func everyReasonHasASentenceAndNoneOfThemIsEmpty() {
        // A reason with no copy would fall through to its own case name.
        let reasons: [APIFailure] = [
            .reported, .unexpectedStatus, .malformedResponse, .nonHTTPResponse,
            .malformedRequestURL, .insecureTransport, .userPresenceEnrollmentUnavailable,
            .userPresenceProofUnavailable, .userPresenceFingerprintMismatch,
            .operationKindMismatch, .invitationRefused, .invitationUnknown,
            .invitationAlreadyUsed, .invitationExpired,
        ]
        for reason in reasons {
            let shown = APIError.message(for: APIError(reason, statusCode: 500, code: "X"))
            #expect(!shown.isEmpty)
            #expect(shown.contains(" "), "\(reason) resolved to a key rather than a sentence")
        }
    }

    @Test
    func aStatusWithNoReasonSaysTheStatusRatherThanNothing() {
        let shown = APIError.message(for: APIError(.unexpectedStatus, statusCode: 503))
        #expect(shown.contains("503"))
    }

    @Test
    func copyTheAppAlreadyLookedUpIsShownUnchanged() {
        let message = String(localized: "The Spark did not apply this setting.")
        #expect(APIError.message(for: APIError(.local(message: message))) == message)
    }

    @Test
    func somethingThatIsNotAnAPIErrorStillGetsASentence() {
        struct Other: Error { let secret = "sk-live-4f3a" }
        let shown = APIError.message(for: Other())
        #expect(!shown.contains("sk-live"))
        #expect(shown == String(localized: .requestDidNotComplete))
    }
}
