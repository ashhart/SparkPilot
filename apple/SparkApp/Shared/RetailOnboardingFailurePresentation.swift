import Foundation
import Network
import Observation
import SparkAPI
import SparkBootstrap
import SparkCore
import SparkDiscovery
import SparkDesignSystem
import SparkLibrary
import SparkIntents
import SparkSecurity
import SparkTransport
enum RetailOnboardingFailurePresentation {

    /// Distinguish rejected local input from a Spark that could not be reached.
    static func describe(credentialError error: any Error) -> String? {
        guard let error = error as? SetupNetworkCredentialError else { return nil }
        switch error {
        case .emptySSID:
            return String(localized: "Enter the Spark Wi-Fi name from the Quick Start card.")
        case .ssidPrefixTooShort:
            return String(
                localized: "Enter at least the first three characters of the Spark Wi-Fi name."
            )
        case .ssidTooLong, .ssidPrefixTooLong:
            return String(localized: "That Wi-Fi name is longer than a network name can be.")
        case .invalidPassphrase:
            return String(
                localized:
                    "A Wi-Fi password is between 8 and 63 characters. Check the Quick Start card."
            )
        case .unsupportedSetupURL:
            return String(
                localized: "The setup web address on that code is not one this app can open."
            )
        }
    }

    static func describe(joinError error: SetupNetworkJoinError) -> String? {
        switch error {
        case .unsupportedPlatform:
            return String(
                localized: "This device cannot join a Spark's setup Wi-Fi. Use an iPhone or iPad."
            )
        case .invalidSSIDPrefix:
            return String(
                localized:
                    "This device could not search for that name. Enter more of it and try again."
            )
        case .invalidConfiguration:
            return String(
                localized:
                    "That Wi-Fi name and password were not accepted. Check the Quick Start card."
            )
        case .applicationNotForeground:
            return String(localized: "Keep Spark on screen while the Wi-Fi prompt appears.")
        case .requestPending:
            return String(
                localized: "A Wi-Fi request is already in progress. Wait a moment and try again."
            )
        case .connectionTimedOut:
            return String(
                localized:
                    "The Spark Wi-Fi did not connect. Check that the Spark is powered on and nearby."
            )
        case .userDenied, .systemDenied, .failed:
            return nil
        }
    }

    /// Qualify the package's RuntimeBootstrapError to avoid the app's unconfigured-runtime error of the same name.
    static func describe(preflightError error: any Error) -> String {
        guard let error = error as? SparkBootstrap.RuntimeBootstrapError else {
            return String(
                localized:
                    "This Spark could not be checked. Confirm it is on this network and try again."
            )
        }
        switch error {
        // Keep diagnostic preflight detail out of owner-facing copy.
        case .preflightUnavailable:
            return String(
                localized:
                    "This Spark did not answer the check. Nothing was installed; try checking it again."
            )
        case .ssh(.authenticationFailed):
            return String(localized: "That username or password was not accepted by this Spark.")
        case .ssh(.hostKey(.changed)):
            return changedHostKeyMessage
        default:
            return String(
                localized:
                    "This Spark could not be checked. Confirm it is on this network and try again."
            )
        }
    }

    /// The host whose recorded SSH key differs from the one it now presents, if that is what failed.
    static func changedHostKeyHost(in error: any Error) -> String? {
        guard let error = error as? SparkBootstrap.RuntimeBootstrapError,
            case .ssh(.hostKey(.changed(let host, _, _))) = error
        else { return nil }
        return host
    }

    static var changedHostKeyMessage: String {
        String(
            localized:
                "This Spark's SSH identity has changed since this device last connected. That is expected after a factory reset; otherwise do not continue on this network."
        )
    }

    /// Only a rejected login proves the password is wrong; anything else is the Spark or the network.
    static func installRejectedAdministratorPassword(_ error: any Error) -> Bool {
        guard let error = error as? SparkBootstrap.RuntimeBootstrapError else { return false }
        if case .ssh(.authenticationFailed) = error { return true }
        return false
    }

    /// One line on why the signed installation stopped, without remote output.
    static func describe(installError error: any Error) -> String {
        guard let error = error as? SparkBootstrap.RuntimeBootstrapError else {
            return String(
                localized:
                    "The installation did not finish. Make sure the Spark is powered on and on your Wi-Fi, then try again."
            )
        }
        switch error {
        case .ssh(.authenticationFailed):
            return String(localized: "That username or password was not accepted by this Spark.")
        case .ssh(.hostKey(.changed)):
            return changedHostKeyMessage
        case .ssh:
            return String(
                localized:
                    "The connection to your Spark dropped. Wait for it to finish starting, then try again."
            )
        default:
            return String(
                localized:
                    "The installation did not finish. Make sure the Spark is powered on and on your Wi-Fi, then try again."
            )
        }
    }

    /// Whether the Spark stopped the install before it touched anything.
    static func isPreflightRefusal(_ error: SparkBootstrap.RuntimeBootstrapError) -> Bool {
        switch error {
        case .preflightBlocked, .preflightUnavailable: true
        default: false
        }
    }

    /// Turn a pairing failure into something the owner can act on.
    static func describe(pairingError error: any Error) -> String {
        guard let pairing = error as? FirstOwnerPairingError else {
            return String(localized: "Pairing could not be completed.")
        }
        switch pairing {
        case .authorityKeyDoesNotMatchFingerprint, .malformedAuthorityKey:
            return
                String(
                    localized: """
                        This Spark's identity did not check out. Do not continue on \
                        this network; set the Spark up again on a network you trust.
                        """
                )
        case .invitationExpired:
            return
                String(
                    localized:
                        "The pairing invitation expired. Tap Install Again to create a fresh one; your Spark setup will be kept."
                )
        case .notAnOwnerInvitation:
            return String(
                localized: "This Spark already has an owner. Ask them to invite this device."
            )
        case .invitationSignatureInvalid, .challengeSignatureInvalid:
            return
                String(
                    localized: """
                        This Spark's pairing message was not signed by the Spark \
                        itself. Do not continue on this network.
                        """
                )
        case .userPresenceDeclined:
            return
                String(
                    localized:
                        "Pairing was cancelled. Confirm with Face ID, Touch ID, or your device passcode to try again."
                )
        case .userPresenceUnavailable:
            return
                String(
                    localized:
                        "Set up Face ID, Touch ID, or a device passcode on this Apple device, then try pairing again."
                )
        case .userPresenceKeyUnavailable:
            return
                String(
                    localized:
                        "This Apple device could not create its protected presence key. Unlock it and try again."
                )
        case .presenceKeyFingerprintMissing, .presenceKeyFingerprintMismatch:
            return
                String(
                    localized:
                        "The Spark did not confirm the protected key registered for this device. Pairing was not trusted; try again."
                )
        case .claimFailed(let detail)
        where detail.contains(String(localized: "already has an owner")):
            return String(
                localized: "This Spark already has an owner. Ask them to invite this device."
            )
        default:
            return String(localized: "Pairing could not be completed. You can try again.")
        }
    }

    static func needsRuntimeReinstall(after error: any Error) -> Bool {
        guard let pairing = error as? FirstOwnerPairingError else { return false }
        switch pairing {
        case .invitationExpired:
            return true
        case .claimFailed(let detail):
            return detail.localizedCaseInsensitiveContains(
                String(localized: "invitation has expired")
            )
                || detail.localizedCaseInsensitiveContains(String(localized: "invitation expired"))
        default:
            return false
        }
    }

    /// Retain SSH credentials only for safe retries; erase them immediately after identity or signature failure.
    static func shouldRetainAdministratorPassword(after error: any Error) -> Bool {
        guard let pairing = error as? FirstOwnerPairingError else { return true }
        switch pairing {
        case .malformedAuthorityKey, .authorityKeyDoesNotMatchFingerprint,
            .malformedInvitation, .invitationSignatureInvalid, .invitationForAnotherNode,
            .notAnOwnerInvitation, .malformedChallenge, .challengeSignatureInvalid,
            .presenceKeyFingerprintMissing, .presenceKeyFingerprintMismatch, .unexpectedRole,
            .grantForAnotherDevice, .malformedAuthorityCertificate, .malformedGrant,
            .transportNotPinnedToNode, .insecureRoute:
            return false
        case .claimFailed(let detail)
        where detail.localizedCaseInsensitiveContains(String(localized: "already has an owner")):
            return false
        default:
            return true
        }
    }

    static func describe(additionalPairingError error: any Error) -> String {
        if error is AdditionalDevicePairingPackageError {
            return
                String(
                    localized:
                        "That pairing invitation could not be verified. Ask the owner to create a new one."
                )
        }
        if let error = error as? AdditionalDevicePairingError,
            error == .grantForAnotherSpark
        {
            return String(
                localized: "The Spark returned a grant for a different device. Pairing was stopped."
            )
        }
        return describe(pairingError: error)
    }

    static func describe(batchPairingError error: any Error) -> String {
        if error is BatchAdditionalDevicePairingPackageError {
            return String(
                localized:
                    "That multi-Spark package is invalid, expired, or was made for another device."
            )
        }
        if error is BatchPairingCoordinatorError {
            return String(
                localized:
                    "This package was not issued to this Apple device. Nothing was claimed."
            )
        }
        return describe(additionalPairingError: error)
    }

    static func describe(batchInvitationError error: any Error) -> String {
        if error is BatchAdditionalDevicePairingPackageError
            || error is BatchInvitationCoordinatorError
        {
            return String(
                localized:
                    "The multi-Spark handoff could not be verified. Check the selected Sparks and create it again."
            )
        }
        return describe(pairingError: error)
    }

    static func describe(joinCodeError error: any Error) -> String {
        guard let error = error as? PairingJoinCodeError else {
            return describe(additionalPairingError: error)
        }
        switch error {
        case .runtimeUpdateRequired:
            return String(
                localized:
                    "Update your Spark from the owner device to use six-digit pairing, or scan the QR invitation now."
            )
        case .invalidFingerprint:
            return String(
                localized:
                    "Copy the full Spark fingerprint from the paired owner's Add Device screen, or scan its QR invitation."
            )
        case .invalidCode:
            return String(localized: "Enter the six-digit code shown on your paired Apple device.")
        case .tooManyAttempts(let retryAfterSeconds):
            let minutes = max(1, (retryAfterSeconds + 59) / 60)
            return String(localized: .joinCodesLocked(minutes: minutes))
        case .rejected:
            return
                String(
                    localized:
                        "That code is wrong, expired, or has already been used. Create a new code and try again."
                )
        case .certificateMismatch:
            return
                String(
                    localized:
                        "The Spark identity changed while pairing, so SparkPilot stopped without trusting it."
                )
        case .insecureRoute, .malformedResponse:
            return
                String(
                    localized:
                        "This Spark could not provide a safe pairing response. Update its runtime and try again."
                )
        case .unavailable:
            return
                String(
                    localized:
                        "The Spark could not be reached. Keep both devices on the same Wi-Fi and try again."
                )
        }
    }

}
