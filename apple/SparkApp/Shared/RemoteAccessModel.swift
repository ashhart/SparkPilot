import Foundation
import Observation
import SparkAPI
import SparkDesignSystem
import SparkSecurity

actor DeviceLocalRemoteAccessCache {
    static let shared = DeviceLocalRemoteAccessCache()

    func load(route: URL) -> RemoteStatus? {
        guard let data = UserDefaults.standard.data(forKey: key(route)) else { return nil }
        return try? JSONDecoder().decode(RemoteStatus.self, from: data)
    }

    func save(_ status: RemoteStatus, route: URL) {
        guard let data = try? JSONEncoder().encode(status) else { return }
        UserDefaults.standard.set(data, forKey: key(route))
    }

    private func key(_ route: URL) -> String {
        let encoded = Data(route.absoluteString.utf8).base64EncodedString()
        return "spark.remote-access.v1." + encoded
    }
}

@MainActor
@Observable
public final class RemoteAccessModel {
    public internal(set) var status: RemoteStatus?
    public private(set) var isRefreshing = false
    public internal(set) var isEnabling = false
    public private(set) var isDisabling = false
    public internal(set) var isOptimisticallyEnabled = false
    public private(set) var isOptimisticallyDisabled = false
    public private(set) var isConfirmingEnable = false
    public private(set) var isConfirmingDisable = false
    public internal(set) var isShowingCachedStatus = false
    public internal(set) var errorMessage: String?
    public internal(set) var lastOperation: SparkAPI.Operation?
    public internal(set) var pendingReview: GeneratedAPI.ModelActionPreview?
    /// Only a fresh pinned overlay request from this device can establish its reachability.
    public internal(set) var verifiedPrivateRouteHostname: String?
    @ObservationIgnored var privateRouteVerificationGeneration = 0
    /// Where the one-tap enable is; the screen shows progress, the sign-in link, or the next action from it.
    public internal(set) var turnOnPhase: RemoteAccessTurnOnPhase = .idle
    /// The owner's one-time Tailscale sign-in link while the Spark waits for it.
    public internal(set) var signInURL: URL?
    public internal(set) var overlayPreferences: GeneratedAPI.RemoteOverlayPreferences?
    public internal(set) var overlayPreferencesError: String?
    public internal(set) var isChangingOverlayPreferences = false
    @ObservationIgnored var overlayChangeKey: UUID?
    @ObservationIgnored var pendingOverlayChange: GeneratedAPI.ConfigureRemoteOverlayRequest?

    public let route: URL
    @ObservationIgnored var connectedRemoteRoute: URL?

    @ObservationIgnored
    let runtime: any RemoteAccessReading
    @ObservationIgnored
    let userPresenceAuthorizer: any UserPresenceAuthorizing
    @ObservationIgnored
    let presenceEnrollmentProvider: (any DeviceManagementProviding)?
    @ObservationIgnored
    let routeRegistration: any RemoteAccessRouteRegistering
    @ObservationIgnored
    let operationDelay: @Sendable (Duration) async throws -> Void
    @ObservationIgnored
    let maximumOperationPolls: Int
    /// A one-tap enable waits for a person to sign in, so it polls far longer than other operations.
    @ObservationIgnored
    let maximumSignInPolls: Int
    @ObservationIgnored
    private var disableKey: UUID?
    @ObservationIgnored
    var enableKey: UUID?
    @ObservationIgnored
    var presenceEnrollmentKey: UUID?
    @ObservationIgnored
    private var hasLoaded = false

    /// Require a client pinned to this Spark; never default to shared system trust.
    public init(
        route: URL,
        runtime: any RemoteAccessReading,
        routeRegistration: any RemoteAccessRouteRegistering,
        userPresenceAuthorizer: any UserPresenceAuthorizing = SystemUserPresenceAuthorizer(),
        maximumOperationPolls: Int = 300,
        maximumSignInPolls: Int = 720,
        operationDelay: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        }
    ) {
        self.route = route
        self.runtime = runtime
        self.routeRegistration = routeRegistration
        self.userPresenceAuthorizer = userPresenceAuthorizer
        self.presenceEnrollmentProvider = runtime as? any DeviceManagementProviding
        self.maximumOperationPolls = max(1, maximumOperationPolls)
        self.maximumSignInPolls = max(1, maximumSignInPolls)
        self.operationDelay = operationDelay
    }

    /// `nil` until this device has live or explicitly labelled cached state.
    public var cardState: RemoteAccessCardState? {
        guard let current = effectiveStatus else { return nil }
        return RemoteAccessCardState(
            enabled: current.enabled,
            mode: RemoteAccessModeValue(rawValue: current.mode.rawValue) ?? .disabled,
            health: RemoteAccessHealthValue(rawValue: current.health.rawValue) ?? .disabled,
            hostname: current.hostname
        )
    }

    public var showsEnableUnavailableNotice: Bool {
        status?.enabled == false && !isShowingCachedStatus && !canEnablePrivateOverlay
            && !isRefreshing && !isDisabling && !isEnabling
    }

    public var canEnablePrivateOverlay: Bool {
        !isShowingCachedStatus && !isWorking
            && status?.enabled == false
            && status?.availableModes.contains(.privateOverlay) == true
    }

    public var isPrivateRouteVerified: Bool {
        !isShowingCachedStatus && !isRefreshing && status?.enabled == true
            && status?.mode == .privateOverlay && verifiedPrivateRouteHostname != nil
            && [status?.hostname, status?.privateOverlayAddress].compactMap { $0 }
                .contains(verifiedPrivateRouteHostname ?? "")
    }

    public func invalidatePrivateRouteVerification() {
        privateRouteVerificationGeneration += 1
        verifiedPrivateRouteHostname = nil
    }

    public var privateOverlayProviderLabel: String {
        status?.privateOverlayProvider == "tailscale"
            ? String(localized: "Tailscale") : String(localized: "Private overlay")
    }

    public var reviewMessage: String {
        pendingReview?.warnings.map(\.ownerExplanation).joined(separator: "\n\n") ?? ""
    }

    public var disableConfirmationTitle: String {
        status?.mode == .privateOverlay
            ? String(localized: "Stop Using Private Route?")
            : String(localized: "Turn Off Remote Access?")
    }

    public var disableActionTitle: String {
        status?.mode == .privateOverlay
            ? String(localized: "Stop Using Private Route")
            : String(localized: "Turn Off Remote Access")
    }

    private var effectiveStatus: RemoteStatus? {
        if isOptimisticallyDisabled {
            return RemoteStatus(enabled: false, mode: .disabled, health: .disabled)
        }
        if isOptimisticallyEnabled {
            return RemoteStatus(
                enabled: true,
                mode: .privateOverlay,
                health: .starting,
                hostname: pendingReview?.evidence.remote?.hostname,
                availableModes: status?.availableModes ?? [],
                privateOverlayProvider: status?.privateOverlayProvider
            )
        }
        return status
    }

    public func loadIfNeeded(refreshIfLoaded: Bool = false) async {
        guard !hasLoaded else {
            if refreshIfLoaded { await refreshAfterReturning() }
            return
        }
        hasLoaded = true
        if let cached = await DeviceLocalRemoteAccessCache.shared.load(route: route) {
            status = cached
            isShowingCachedStatus = true
        }
        await refresh()
    }

    /// Returning from sign-in may overlap the last check; wait for it instead of dropping the refresh.
    public func refreshAfterReturning() async {
        do {
            while isRefreshing || isDisabling || isEnabling || isChangingOverlayPreferences {
                try await Task.sleep(for: .milliseconds(100))
            }
            try Task.checkCancellation()
            await refresh()
        } catch {
            // Leaving the screen cancels only this refresh, never the Spark's operation.
        }
    }

    public func refresh() async {
        guard !isRefreshing, !isDisabling, !isEnabling, !isChangingOverlayPreferences else {
            return
        }
        isRefreshing = true
        verifiedPrivateRouteHostname = nil
        errorMessage = nil
        defer { isRefreshing = false }
        do {
            let loaded = try await readRemoteStatus(refreshHealth: false)
            status = loaded
            if let routeError = await reconcilePrivateOverlayRoute(for: loaded) {
                errorMessage = routeError
            }
            isShowingCachedStatus = false
            await DeviceLocalRemoteAccessCache.shared.save(loaded, route: route)
            await readOverlayPreferences()
        } catch {
            overlayPreferences = nil
            isShowingCachedStatus = status != nil
            errorMessage =
                status == nil
                ? String(
                    localized: "Remote status is unavailable while the Spark cannot be reached."
                )
                : String(
                    localized:
                        "The Spark cannot be reached. Showing its last known remote-access status."
                )
        }
    }

    /// Offer a recheck when an enabled remote route is unhealthy.
    public var isRemoteRouteUnhealthy: Bool {
        guard let status, status.enabled else { return false }
        return status.health == .degraded || status.health == .failed
    }

    /// Recheck remote health and adopt a recovered private-overlay address after pinned verification.
    public func recheckRemoteHealth() async {
        guard !isRefreshing, !isDisabling, !isEnabling, !isChangingOverlayPreferences else {
            return
        }
        isRefreshing = true
        verifiedPrivateRouteHostname = nil
        errorMessage = nil
        defer { isRefreshing = false }
        do {
            let refreshed = try await readRemoteStatus(refreshHealth: true)
            status = refreshed
            if let routeError = await reconcilePrivateOverlayRoute(for: refreshed) {
                errorMessage = routeError
            }
            isShowingCachedStatus = false
            await DeviceLocalRemoteAccessCache.shared.save(refreshed, route: route)
            await readOverlayPreferences()
        } catch {
            isShowingCachedStatus = status != nil
            errorMessage = String(
                localized:
                    "The Spark could not be reached to recheck the route. Try again on the local network."
            )
        }
    }

    public func preparePrivateOverlayEnable() async {
        guard canEnablePrivateOverlay, !isEnabling else { return }
        errorMessage = nil
        let idempotencyKey = enableKey ?? UUID()
        enableKey = idempotencyKey
        do {
            let preview = try await runtime.previewRemoteEnable(
                route: route,
                body: RemotePreviewRequest(mode: .privateOverlay),
                idempotencyKey: idempotencyKey
            )
            guard preview.action == .remoteEnable,
                preview.evidence.remote?.requestedModeAvailable == true,
                preview.evidence.remote?.provider == "tailscale"
            else {
                enableKey = nil
                errorMessage =
                    String(
                        localized:
                            "The Spark did not return a valid Tailscale enablement review. Refresh and try again."
                    )
                return
            }
            guard preview.blockers.isEmpty else {
                enableKey = nil
                errorMessage = preview.blockers[0].ownerExplanation
                return
            }
            pendingReview = preview
            isConfirmingEnable = true
        } catch {
            if Self.isDefinitiveRejection(error) { enableKey = nil }
            errorMessage = RemoteAccessFailurePresentation.describeEnableError(error)
        }
    }

    public func cancelEnableConfirmation() {
        isConfirmingEnable = false
        pendingReview = nil
        enableKey = nil
    }

    public func confirmEnable() async {
        guard !isEnabling, let preview = pendingReview else { return }
        isConfirmingEnable = false
        isEnabling = true
        errorMessage = nil
        let idempotencyKey = enableKey ?? UUID()
        enableKey = idempotencyKey
        defer { isEnabling = false }

        do {
            let presence = try await userPresenceAuthorizer.authorize(
                localizedReason: String(
                    localized: "Confirm using this Spark's existing Tailscale connection."
                )
            )
            isOptimisticallyEnabled = true
            let accepted = try await enableRemote(
                previewDigest: preview.previewDigest,
                idempotencyKey: idempotencyKey,
                userPresence: presence
            )
            lastOperation = accepted
            let operation = try await waitForTerminalOperation(accepted)
            lastOperation = operation
            guard operation.state == .succeeded else {
                enableKey = nil
                throw APIError(
                    .local(
                        message: String(
                            localized: "The Spark could not finish enabling private remote access."
                        )
                    ),
                    code: operation.errorCode ?? "REMOTE_ENABLE_FAILED"
                )
            }
            enableKey = nil
            pendingReview = nil
            let confirmed = RemoteStatus(
                enabled: true,
                mode: .privateOverlay,
                health: .starting,
                hostname: preview.evidence.remote?.hostname,
                availableModes: status?.availableModes ?? [.privateOverlay],
                privateOverlayProvider: preview.evidence.remote?.provider
            )
            status = confirmed
            isOptimisticallyEnabled = false
            verifiedPrivateRouteHostname = nil
            do {
                let loaded = try await runtime.remoteStatus(route: route)
                status = loaded
                isShowingCachedStatus = false
                await DeviceLocalRemoteAccessCache.shared.save(loaded, route: route)
                if !loaded.enabled || loaded.mode != .privateOverlay {
                    verifiedPrivateRouteHostname = nil
                    errorMessage =
                        String(
                            localized:
                                "The operation finished, but the Spark did not confirm its private route. Refresh while on the local network."
                        )
                } else {
                    if let routeError = await reconcilePrivateOverlayRoute(for: loaded) {
                        errorMessage = routeError
                    }
                }
            } catch {
                isShowingCachedStatus = true
                errorMessage =
                    String(
                        localized:
                            "Private remote access was enabled, but its live health could not be loaded. Refresh while on the local network."
                    )
            }
        } catch {
            if Self.isDefinitiveRejection(error) { enableKey = nil }
            errorMessage = RemoteAccessFailurePresentation.describeEnableError(error)
        }
        isOptimisticallyEnabled = false
    }

    public func prepareDisable() async {
        guard status?.enabled == true, !isDisabling, !isChangingOverlayPreferences else { return }
        errorMessage = nil
        let idempotencyKey = disableKey ?? UUID()
        disableKey = idempotencyKey
        do {
            let preview = try await runtime.previewRemoteDisable(
                route: route,
                idempotencyKey: idempotencyKey
            )
            guard preview.action == .remoteDisable else {
                disableKey = nil
                errorMessage =
                    String(
                        localized:
                            "The Spark did not return a valid remote-access disablement review. Refresh and try again."
                    )
                return
            }
            guard preview.blockers.isEmpty else {
                disableKey = nil
                errorMessage = preview.blockers[0].ownerExplanation
                return
            }
            pendingReview = preview
            isConfirmingDisable = true
        } catch {
            if Self.isDefinitiveRejection(error) { disableKey = nil }
            errorMessage = RemoteAccessFailurePresentation.describeDisableError(error)
        }
    }

    public func cancelDisableConfirmation() {
        isConfirmingDisable = false
        pendingReview = nil
        disableKey = nil
    }

    public func confirmDisable() async {
        guard !isDisabling else { return }
        guard status?.enabled == true, let preview = pendingReview else {
            isConfirmingDisable = false
            return
        }
        isConfirmingDisable = false
        isDisabling = true
        errorMessage = nil
        defer { isDisabling = false }

        let idempotencyKey = disableKey ?? UUID()
        disableKey = idempotencyKey
        do {
            let presence = try await userPresenceAuthorizer.authorize(
                localizedReason: status?.mode == .privateOverlay
                    ? String(
                        localized:
                            "Confirm stopping SparkPilot from using this Spark's private route."
                    )
                    : String(localized: "Confirm turning off remote access to this Spark.")
            )
            isOptimisticallyDisabled = true
            let accepted = try await disableRemote(
                previewDigest: preview.previewDigest,
                idempotencyKey: idempotencyKey,
                userPresence: presence
            )
            lastOperation = accepted
            let operation = try await waitForTerminalOperation(accepted)
            lastOperation = operation
            guard operation.state == .succeeded else {
                disableKey = nil
                throw APIError(
                    .local(
                        message: String(
                            localized: "The Spark could not finish turning off remote access."
                        )
                    ),
                    code: operation.errorCode ?? "REMOTE_DISABLE_FAILED"
                )
            }
            disableKey = nil
            pendingReview = nil
            status = RemoteStatus(enabled: false, mode: .disabled, health: .disabled)
            verifiedPrivateRouteHostname = nil
            routeRegistration.unregisterPrivateOverlay(currentRoute: route)
            isOptimisticallyDisabled = false
            do {
                let loaded = try await runtime.remoteStatus(route: route)
                status = loaded
                isShowingCachedStatus = false
                await DeviceLocalRemoteAccessCache.shared.save(loaded, route: route)
                if status?.enabled == true {
                    errorMessage =
                        String(
                            localized: """
                                The Spark finished the request, but still reports remote access as \
                                on. Refresh while near your Spark.
                                """
                        )
                }
            } catch {
                isShowingCachedStatus = true
                errorMessage =
                    String(
                        localized: """
                            Remote access was turned off, but its new status could not be loaded. \
                            Refresh while near your Spark.
                            """
                    )
            }
        } catch {
            isOptimisticallyDisabled = false
            if Self.isDefinitiveRejection(error) { disableKey = nil }
            errorMessage = RemoteAccessFailurePresentation.describeDisableError(error)
        }
    }
}
