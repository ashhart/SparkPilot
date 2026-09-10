import Foundation

/// Resolve typed failure reasons through the main-bundle catalogue without displaying server prose.
extension LocalizedStringResource {
    static func recipeBy(_ source: String) -> Self {
        .init(
            "model.recipe.source",
            defaultValue: "recipe by \(source)",
            comment: "Credits the source of the installation recipe after the model publisher."
        )
    }

    static var requestDidNotComplete: Self {
        .init(
            "api.failed.unknown",
            defaultValue: "The request did not complete. Check the connection and try again.",
            comment: "A failure that is not one of the Spark's own."
        )
    }

    static var sparkRefusedTheRequest: Self {
        .init(
            "api.failed.refused",
            defaultValue: "The Spark refused this request.",
            comment: "The Spark answered with an error and no reason code."
        )
    }

    static var runtimeSigningProtocolMismatch: Self {
        .init(
            "api.failed.protocol.mismatch",
            defaultValue:
                "This app and the Spark's runtime use different sign-in protocols. Update the Spark runtime from a device that still connects, or install the app version that matches the runtime.",
            comment: "The app and the runtime disagree on request signing; update one of them."
        )
    }

    static func sparkRefusedTheRequestWithCode(_ code: String) -> Self {
        .init(
            "api.failed.refused.code",
            defaultValue: "The Spark refused this request. Its reason code is \(code).",
            comment: "The Spark answered with an error; the code is what support can act on."
        )
    }

    static func sparkAnsweredWithStatus(_ status: Int) -> Self {
        .init(
            "api.failed.status",
            defaultValue: "The Spark answered with status \(status) and no reason.",
            comment: "A non-2xx response this build could not read a reason out of."
        )
    }

    static var sparkAnswerUnreadable: Self {
        .init(
            "api.failed.malformed",
            defaultValue: "This app could not read the Spark's answer. Its software may be newer.",
            comment: "A successful response whose body did not match the contract."
        )
    }

    static var answerWasNotFromASpark: Self {
        .init(
            "api.failed.nonhttp",
            defaultValue: "Something on this network answered instead of your Spark.",
            comment: "The response was not HTTP, so it did not come from the runtime."
        )
    }

    static var requestCouldNotBeAddressed: Self {
        .init(
            "api.failed.url",
            defaultValue: "This app could not address the request to your Spark.",
            comment: "A URL the client could not construct."
        )
    }

    static var pairingNeedsASecureRoute: Self {
        .init(
            "api.failed.insecure",
            defaultValue: "Pairing needs a secure route, and this one is not encrypted.",
            comment: "Pairing was attempted over plaintext and refused."
        )
    }

    static var presenceKeyCannotBeEnrolled: Self {
        .init(
            "api.failed.presence.enroll",
            defaultValue: "This Apple device cannot enroll its user-presence key.",
            comment: "The device cannot create the key that proves someone is present."
        )
    }

    static var presenceProofUnavailable: Self {
        .init(
            "api.failed.presence.proof",
            defaultValue: "This Apple device cannot create a user-presence proof.",
            comment: "The device cannot sign a proof that someone is present."
        )
    }

    static var presenceKeyFingerprintMismatch: Self {
        .init(
            "api.failed.presence.fingerprint",
            defaultValue: "The Spark returned a different presence-key fingerprint.",
            comment: "The Spark's answer named a key that is not this device's."
        )
    }

    static var operationIsADifferentJob: Self {
        .init(
            "api.failed.operation.kind",
            defaultValue: "That operation is a different kind of job.",
            comment: "An operation was asked for as an analysis and is something else."
        )
    }

    static var invitationRefused: Self {
        .init(
            "api.failed.invitation.refused",
            defaultValue: "The Spark refused this invitation.",
            comment: "Pairing was refused with 401 or 403."
        )
    }

    static var invitationUnknown: Self {
        .init(
            "api.failed.invitation.unknown",
            defaultValue: "This Spark does not know this invitation.",
            comment: "Pairing was refused with 404."
        )
    }

    static var invitationAlreadyUsed: Self {
        .init(
            "api.failed.invitation.used",
            defaultValue:
                "The invitation has already been used, or this Spark already has an owner.",
            comment: "Pairing was refused with 409."
        )
    }

    static var invitationExpired: Self {
        .init(
            "api.failed.invitation.expired",
            defaultValue: "The invitation has expired.",
            comment: "Pairing was refused with 410."
        )
    }
}

extension LocalizedStringResource {
    public static func developmentSessionEndFailed(_ detail: String) -> Self {
        .init(
            "development.session.end.failed",
            defaultValue:
                "The session could not be ended; reconnect or try End Session again. \(detail)",
            comment: "A terminal could not be ended, followed by the locally translated API error."
        )
    }
}

extension LocalizedStringResource {
    public static func projectDeletionConfirmation(_ name: String) -> Self {
        .init(
            "project.delete.confirmation",
            defaultValue:
                "Deleting “\(name)” permanently removes its files, development workspaces, saved sessions and builds from the Spark, for everyone using it; running terminals will end and this cannot be undone.",
            comment:
                "Destructive project deletion confirmation naming the project and its remote data."
        )
    }
}
