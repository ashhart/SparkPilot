import Foundation

/// Represent failures as typed reasons while retaining remote prose only in bounded diagnosticDetail.
public enum APIFailure: Sendable, Equatable {
    /// Expose the stable contract error code for support while keeping the operator-written message out of UI copy.
    case reported
    /// A status outside 2xx with no envelope this build could read.
    case unexpectedStatus
    /// A 2xx body this build could not decode into the contract's type.
    case malformedResponse
    /// The response was not HTTP at all.
    case nonHTTPResponse
    /// A URL this build could not construct from its own components.
    case malformedRequestURL
    /// The route is not https. Pairing never crosses plaintext.
    case insecureTransport
    /// This device cannot enrol the key that proves someone is present.
    case userPresenceEnrollmentUnavailable
    /// This device cannot produce a user-presence proof for this request.
    case userPresenceProofUnavailable
    /// The Spark answered with a presence key that is not this device's.
    case userPresenceFingerprintMismatch
    /// The operation exists, and is a different kind of job.
    case operationKindMismatch
    /// The Spark would not accept this pairing invitation.
    case invitationRefused
    /// The Spark has never heard of this invitation.
    case invitationUnknown
    /// The invitation has been used, or the Spark already has an owner.
    case invitationAlreadyUsed
    /// The invitation is past its expiry.
    case invitationExpired
    /// Carry only copy already resolved through String(localized:), as enforced by the localisation gate.
    case local(message: String)
}

/// A request that did not succeed, in terms the app can act on.
public struct APIError: Error, Sendable, Equatable {
    /// What went wrong, as a value rather than as prose.
    public let reason: APIFailure
    /// Retain the numeric HTTP status when a response exists.
    public let statusCode: Int?
    /// The contract's reason code when the Spark sent one.
    public let code: String?
    /// Keep bounded wire diagnostics internal to the module until a tested, redacted export exists.
    public let diagnosticDetail: String

    public init(
        _ reason: APIFailure,
        statusCode: Int? = nil,
        code: String? = nil,
        diagnosticDetail: String = ""
    ) {
        self.reason = reason
        self.statusCode = statusCode
        self.code = code
        self.diagnosticDetail = diagnosticDetail
    }
}

extension APIError: LocalizedError {
    /// Resolve localizedDescription through the same catalogue presenter as other visible failures.
    public var errorDescription: String? { APIError.message(for: self) }
}

extension APIError {
    /// Present typed refusal reasons with catalogue fallback rather than response-body prose.
    public static func message(for error: any Error) -> String {
        guard let error = error as? APIError else {
            return String(localized: .requestDidNotComplete)
        }
        return message(for: error)
    }

    public static func message(for error: APIError) -> String {
        switch error.reason {
        case .local(let message): return message
        case .reported:
            guard let code = error.code, !code.isEmpty else {
                return String(localized: .sparkRefusedTheRequest)
            }
            // A protocol mismatch is an update task, not a refusal the owner can diagnose from a code.
            if code == "PROTOCOL_UNSUPPORTED" {
                return String(localized: .runtimeSigningProtocolMismatch)
            }
            // The contract localises documented codes; only an unknown code falls back to the code itself.
            if let known = SparkErrorCopy.message(for: code) { return known }
            return String(localized: .sparkRefusedTheRequestWithCode(code))
        case .unexpectedStatus:
            guard let status = error.statusCode else {
                return String(localized: .sparkRefusedTheRequest)
            }
            return String(localized: .sparkAnsweredWithStatus(status))
        case .malformedResponse: return String(localized: .sparkAnswerUnreadable)
        case .nonHTTPResponse: return String(localized: .answerWasNotFromASpark)
        case .malformedRequestURL: return String(localized: .requestCouldNotBeAddressed)
        case .insecureTransport: return String(localized: .pairingNeedsASecureRoute)
        case .userPresenceEnrollmentUnavailable:
            return String(localized: .presenceKeyCannotBeEnrolled)
        case .userPresenceProofUnavailable: return String(localized: .presenceProofUnavailable)
        case .userPresenceFingerprintMismatch:
            return String(localized: .presenceKeyFingerprintMismatch)
        case .operationKindMismatch: return String(localized: .operationIsADifferentJob)
        case .invitationRefused: return String(localized: .invitationRefused)
        case .invitationUnknown: return String(localized: .invitationUnknown)
        case .invitationAlreadyUsed: return String(localized: .invitationAlreadyUsed)
        case .invitationExpired: return String(localized: .invitationExpired)
        }
    }
}
