import Foundation
import Observation
import SparkAPI
import SparkDesignSystem
import SparkSecurity

/// Where the one-tap enable is, so the screen can show progress, the sign-in link, or the next action.
public enum RemoteAccessTurnOnPhase: Equatable, Sendable {
    case idle
    case reviewing
    case preparing
    case awaitingSignIn
    case awaitingApproval
    case verifying
    case finishing
    case done
    case failed(RemoteAccessNextAction)

    public var isWorking: Bool {
        switch self {
        case .idle, .done, .failed: false
        default: true
        }
    }
}

/// A failure state always ends in something the owner can do.
public struct RemoteAccessNextAction: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case tryAgain
        case checkAgain
        case openTailscaleOnThisDevice
        case none
    }

    public let title: String
    public let message: String
    public let kind: Kind

    public init(title: String, message: String, kind: Kind) {
        self.title = title
        self.message = message
        self.kind = kind
    }
}

extension RemoteAccessModel {
    static let signInStage = "awaiting_owner_login"
    static let approvalStage = "awaiting_tailnet_approval"

    public var canTurnOn: Bool {
        !isShowingCachedStatus && !isWorking
            && status?.enabled == false && !turnOnPhase.isWorking
    }

    public var isTurningOn: Bool { turnOnPhase.isWorking }

    /// One tap: review, confirm presence once, let the Spark set Tailscale up, then record the route here.
    public func turnOn() async {
        guard canTurnOn else { return }
        errorMessage = nil
        signInURL = nil
        turnOnPhase = .reviewing
        guard await runTurnOnOperation() else { return }
        // The refresh that records the route on this device runs once the enable has let go of isEnabling.
        turnOnPhase = .finishing
        await refresh()
        turnOnPhase = finishedPhase()
    }

    /// Review, confirm presence, then follow the Spark's operation to its end; true only when it succeeded.
    private func runTurnOnOperation() async -> Bool {
        isEnabling = true
        defer { isEnabling = false }
        let idempotencyKey = enableKey ?? UUID()
        enableKey = idempotencyKey
        do {
            let preview = try await runtime.previewRemoteEnable(
                route: route,
                body: RemotePreviewRequest(mode: .privateOverlay),
                idempotencyKey: idempotencyKey
            )
            if let blocker = preview.blockers.first {
                enableKey = nil
                turnOnPhase = .failed(Self.nextAction(forBlocker: blocker))
                return false
            }
            guard preview.action == .remoteEnable,
                preview.evidence.remote?.requestedModeAvailable == true
            else {
                enableKey = nil
                turnOnPhase = .failed(Self.staleReviewAction)
                return false
            }
            pendingReview = preview
            let presence = try await userPresenceAuthorizer.authorize(
                localizedReason: String(localized: "Turn on remote access to this Spark.")
            )
            turnOnPhase = .preparing
            let accepted = try await enableRemote(
                previewDigest: preview.previewDigest,
                idempotencyKey: idempotencyKey,
                userPresence: presence
            )
            lastOperation = accepted
            let operation = try await waitForTurnOn(accepted)
            lastOperation = operation
            guard operation.state == .succeeded else {
                enableKey = nil
                turnOnPhase = .failed(
                    Self.nextAction(
                        forOperationCode: operation.errorCode,
                        overlay: await overlayState()
                    )
                )
                return false
            }
            enableKey = nil
            pendingReview = nil
            signInURL = nil
            return true
        } catch {
            if Self.isDefinitiveRejection(error) { enableKey = nil }
            signInURL = nil
            turnOnPhase = .failed(Self.nextAction(for: error, overlay: await overlayState()))
            return false
        }
    }

    public func dismissTurnOnOutcome() {
        turnOnPhase = .idle
        signInURL = nil
    }

    private func finishedPhase() -> RemoteAccessTurnOnPhase {
        guard status?.enabled == true, status?.mode == .privateOverlay else {
            return .failed(
                RemoteAccessNextAction(
                    title: String(localized: "The Spark did not confirm remote access"),
                    message: String(
                        localized:
                            "The setup finished, but the Spark's status does not show the route yet. Check again while on your network."
                    ),
                    kind: .checkAgain
                )
            )
        }
        if isPrivateRouteVerified { return .done }
        return .failed(
            RemoteAccessNextAction(
                title: String(
                    localized: "Remote access is on. This device is not on your tailnet yet."
                ),
                message: String(
                    localized: """
                        Open the Tailscale app on this device, sign in to the same account, then check \
                        the private connection. Until then SparkPilot keeps using your network.
                        """
                ),
                kind: .openTailscaleOnThisDevice
            )
        )
    }

    /// Poll the enable with a longer budget than other operations because it waits for a person.
    private func waitForTurnOn(_ accepted: SparkAPI.Operation) async throws -> SparkAPI.Operation {
        var operation = accepted
        var pollsRemaining = maximumSignInPolls
        await observeTurnOnStage(operation.stage)
        while !Self.isTerminal(operation.state) {
            guard pollsRemaining > 0 else {
                throw APIError(
                    .local(
                        message: String(localized: "The Spark is still turning remote access on.")
                    ),
                    code: "PRIVATE_OVERLAY_LOGIN_TIMEOUT"
                )
            }
            pollsRemaining -= 1
            try await operationDelay(.seconds(1))
            operation = try await runtime.operation(route: route, id: operation.id)
            lastOperation = operation
            await observeTurnOnStage(operation.stage)
        }
        return operation
    }

    private func observeTurnOnStage(_ stage: String?) async {
        switch stage {
        case Self.signInStage:
            turnOnPhase = .awaitingSignIn
            if signInURL == nil { await loadSignInLink() }
        case Self.approvalStage:
            turnOnPhase = .awaitingApproval
        case "verifying_route", "publishing_route":
            turnOnPhase = .verifying
        case "preparing_overlay":
            turnOnPhase = .preparing
        default:
            break
        }
    }

    /// The link is offered only on Tailscale's own sign-in origin; the contract type already refuses anything else.
    private func loadSignInLink() async {
        guard let setup = try? await runtime.remoteOverlaySetup(route: route),
            let url = setup.authorizationURL,
            RemoteOverlaySetup.isTrustedSignInLink(url)
        else { return }
        signInURL = url
    }

    /// What the Spark itself says Tailscale is doing, read after a failure rather than assumed.
    private func overlayState() async -> RemoteOverlaySetup? {
        try? await runtime.remoteOverlaySetup(route: route)
    }

    private static func isTerminal(_ state: SparkAPI.Operation.OperationState) -> Bool {
        switch state {
        case .succeeded, .failed, .cancelled: true
        default: false
        }
    }

    private static var staleReviewAction: RemoteAccessNextAction {
        RemoteAccessNextAction(
            title: String(localized: "The Spark changed while reviewing"),
            message: String(
                localized:
                    "Its Tailscale state moved during the review. Tap Turn On Remote Access again."
            ),
            kind: .tryAgain
        )
    }

    static func nextAction(forBlocker blocker: GeneratedAPI.ModelActionPreviewMessage)
        -> RemoteAccessNextAction
    {
        RemoteAccessNextAction(
            title: String(localized: "Tailscale cannot be set up from here"),
            message: [blocker.ownerExplanation, blocker.recoveryAction]
                .compactMap { $0 }
                .joined(separator: " "),
            kind: .none
        )
    }

    /// What the Spark reports Tailscale is in the middle of, so no failure claims more than was read.
    static func overlayRemains(_ overlay: RemoteOverlaySetup?) -> String {
        guard let overlay else {
            return String(
                localized: """
                    SparkPilot could not read what Tailscale is doing on your Spark, so check it \
                    there before taking it that nothing changed.
                    """
            )
        }
        switch overlay.state {
        case .notInstalled, .unavailable:
            return String(
                localized:
                    "Tailscale is not installed on your Spark, so the attempt left nothing behind."
            )
        case .stopped:
            return String(
                localized: """
                    Tailscale is installed on your Spark and stopped, so the Spark is not on your \
                    tailnet.
                    """
            )
        case .loginRequired:
            return String(
                localized: """
                    Tailscale is installed and running on your Spark, waiting to be signed in: \
                    finishing that sign-in later would put the Spark on your tailnet. To undo it, \
                    run `sudo tailscale logout` then `sudo systemctl disable --now tailscaled` on \
                    the Spark.
                    """
            )
        case .approvalRequired:
            return String(
                localized: """
                    Tailscale is signed in on your Spark and waiting for your tailnet's admin to \
                    approve it, and it joins as soon as they do. To undo it, run `sudo tailscale \
                    logout` then `sudo systemctl disable --now tailscaled` on the Spark.
                    """
            )
        case .connecting, .ready:
            return String(
                localized: """
                    Tailscale is signed in and running on your Spark, so the Spark is on your \
                    tailnet even though SparkPilot did not record the route. To undo it, run \
                    `sudo tailscale logout` then `sudo systemctl disable --now tailscaled` on the \
                    Spark.
                    """
            )
        }
    }

    static func nextAction(
        forOperationCode code: String?,
        overlay: RemoteOverlaySetup? = nil
    ) -> RemoteAccessNextAction {
        let state = overlayRemains(overlay)
        switch code {
        case "PRIVATE_OVERLAY_LOGIN_TIMEOUT":
            return RemoteAccessNextAction(
                title: String(localized: "The sign-in link expired"),
                message: String(localized: .remoteSignInExpired(state: state)),
                kind: .tryAgain
            )
        case "PRIVATE_OVERLAY_SETUP_FAILED":
            return RemoteAccessNextAction(
                title: String(localized: "The Spark could not set Tailscale up"),
                message: String(localized: .remoteSetupFailed(state: state)),
                kind: .tryAgain
            )
        case "PRIVATE_OVERLAY_ROUTE_UNVERIFIED":
            return RemoteAccessNextAction(
                title: String(
                    localized: "Tailscale is signed in, but the route is not answering yet"
                ),
                message: String(localized: .remoteRouteUnverified(state: state)),
                kind: .checkAgain
            )
        case "OPERATION_CANCELLED":
            return RemoteAccessNextAction(
                title: String(localized: "Turning on remote access was cancelled"),
                message: String(localized: .remoteEnableCancelled(state: state)),
                kind: .tryAgain
            )
        default:
            return RemoteAccessNextAction(
                title: String(localized: "Remote access is still off"),
                message: String(localized: .remoteEnableUnfinished(state: state)),
                kind: .tryAgain
            )
        }
    }

    static func nextAction(
        for error: any Error,
        overlay: RemoteOverlaySetup? = nil
    ) -> RemoteAccessNextAction {
        if error is UserPresenceAuthorizationError {
            return RemoteAccessNextAction(
                title: String(localized: "Remote access is still off"),
                message: String(
                    localized: "This device could not confirm you are present. Try again."
                ),
                kind: .tryAgain
            )
        }
        if let api = error as? APIError {
            switch api.code {
            case "PRIVATE_OVERLAY_LOGIN_TIMEOUT", "PREVIEW_STALE", "REMOTE_ENABLE_FAILED",
                "PRIVATE_OVERLAY_SETUP_FAILED", "PRIVATE_OVERLAY_ROUTE_UNVERIFIED":
                return nextAction(forOperationCode: api.code, overlay: overlay)
            case "USER_PRESENCE_REQUIRED", "USER_PRESENCE_INVALID", "USER_PRESENCE_EXPIRED",
                "USER_PRESENCE_NOT_REGISTERED", "USER_PRESENCE_SIGNER_UNAVAILABLE",
                "USER_PRESENCE_ENROLLMENT_UNAVAILABLE":
                return nextAction(for: UserPresenceAuthorizationError.declined)
            default:
                break
            }
            if api.statusCode == 401 || api.statusCode == 403 {
                return RemoteAccessNextAction(
                    title: String(localized: "Only the owner can turn this on"),
                    message: String(
                        localized:
                            "Use the Apple device that set this Spark up, or ask its owner to turn remote access on."
                    ),
                    kind: .none
                )
            }
        }
        return RemoteAccessNextAction(
            title: String(localized: "Remote access is still off"),
            message: String(
                localized: "Check the connection to your Spark and try again while near it."
            ),
            kind: .tryAgain
        )
    }
}
