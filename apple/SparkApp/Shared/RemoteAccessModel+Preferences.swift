import Foundation
import SparkAPI
import SparkSecurity

extension RemoteAccessModel {
    public var isWorking: Bool {
        isRefreshing || isEnabling || isDisabling || isChangingOverlayPreferences
    }

    public var canConfigureOverlayPreferences: Bool {
        !isWorking && !isShowingCachedStatus && overlayPreferences != nil && overlayChangeKey == nil
    }

    public var canRetryOverlayPreferenceChange: Bool {
        !isWorking && pendingOverlayChange != nil && overlayChangeKey != nil
    }

    func readOverlayPreferences() async {
        do {
            let preferences = try await performRemoteRequest { candidate in
                try await runtime.remoteOverlayPreferences(route: candidate)
            }
            overlayPreferences = preferences
            overlayPreferencesError = nil
            if let change = pendingOverlayChange,
                change.enabled.map({ $0 == preferences.enabled })
                    ?? change.acceptDns.map({ $0 == preferences.acceptDns }) ?? false
            {
                clearOverlayChange()
            }
        } catch {
            overlayPreferences = nil
            overlayPreferencesError = String(
                localized:
                    "The Spark's VPN and DNS settings could not be read; check its connection and runtime update."
            )
        }
    }

    public func setOverlayDNS(_ enabled: Bool) async {
        await changeOverlayPreference(.init(acceptDns: enabled))
    }

    public func resumeOverlayVPN() async {
        await changeOverlayPreference(.init(enabled: true))
    }

    public func pauseOverlayVPN(confirmed: Bool) async {
        guard confirmed else { return }
        await changeOverlayPreference(.init(enabled: false))
    }

    public func retryOverlayPreferenceChange() async {
        guard canRetryOverlayPreferenceChange, let change = pendingOverlayChange else { return }
        await changeOverlayPreference(change, retry: true)
    }

    private func clearOverlayChange() {
        overlayChangeKey = nil
        pendingOverlayChange = nil
    }

    private func changeOverlayPreference(
        _ change: GeneratedAPI.ConfigureRemoteOverlayRequest,
        retry: Bool = false
    ) async {
        guard retry ? canRetryOverlayPreferenceChange : canConfigureOverlayPreferences else {
            return
        }
        isChangingOverlayPreferences = true
        overlayPreferencesError = nil
        let key = overlayChangeKey ?? UUID()
        overlayChangeKey = key
        pendingOverlayChange = change
        let reason =
            change.enabled == false
            ? String(localized: "Pause Tailscale on this Spark; remote access will disconnect.")
            : String(localized: "Confirm changing this Spark's Tailscale settings.")
        var accepted = false
        var requestAttempted = false
        do {
            let presence = try await userPresenceAuthorizer.authorize(localizedReason: reason)
            requestAttempted = true
            invalidatePrivateRouteVerification()
            let operation = try await configureOverlay(
                change,
                key: key,
                presence: presence,
                reason: reason
            )
            accepted = true
            lastOperation = operation
            let terminal = try await waitForTerminalOperation(operation)
            lastOperation = terminal
            guard terminal.state == .succeeded else {
                clearOverlayChange()
                overlayPreferencesError = String(
                    localized:
                        "The Spark could not apply that Tailscale setting; check its connection and try again."
                )
                await readOverlayPreferencesPreservingError()
                isChangingOverlayPreferences = false
                return
            }
            clearOverlayChange()
            await readOverlayPreferences()
            await refreshConnectionAfterOverlayChange()
            if let preferences = overlayPreferences,
                change.enabled.map({ $0 != preferences.enabled })
                    ?? change.acceptDns.map({ $0 != preferences.acceptDns }) ?? false
            {
                overlayPreferencesError = String(
                    localized:
                        "The Spark's current setting differs from the requested change; check it before trying again."
                )
            }
        } catch {
            if !requestAttempted {
                clearOverlayChange()
                overlayPreferencesError = String(
                    localized: "The Tailscale setting was not changed."
                )
                isChangingOverlayPreferences = false
                return
            }
            if Self.isDefinitiveRejection(error) || (!accepted && error is CancellationError) {
                clearOverlayChange()
            }
            overlayPreferences = nil
            overlayPreferencesError =
                change.enabled == false
                ? String(
                    localized:
                        "The Spark may have paused Tailscale; return to its local network and refresh to confirm."
                )
                : String(
                    localized:
                        "The Tailscale change could not be confirmed; refresh or retry the same change."
                )
        }
        isChangingOverlayPreferences = false
    }

    private func refreshConnectionAfterOverlayChange() async {
        do {
            let refreshed = try await readRemoteStatus(refreshHealth: true)
            status = refreshed
            isShowingCachedStatus = false
            errorMessage = nil
            if overlayPreferences?.enabled == true {
                errorMessage = await reconcilePrivateOverlayRoute(for: refreshed)
            }
            await DeviceLocalRemoteAccessCache.shared.save(refreshed, route: route)
        } catch {
            isShowingCachedStatus = status != nil
            errorMessage = String(
                localized:
                    "The setting changed, but the Spark's connection could not be checked yet."
            )
        }
    }

    private func readOverlayPreferencesPreservingError() async {
        let message = overlayPreferencesError
        await readOverlayPreferences()
        overlayPreferencesError = message
    }

    private func configureOverlay(
        _ change: GeneratedAPI.ConfigureRemoteOverlayRequest,
        key: UUID,
        presence: any UserPresenceProofSigning,
        reason: String
    ) async throws -> SparkAPI.Operation {
        do {
            return try await performRemoteRequest { candidate in
                try await runtime.configureRemoteOverlay(
                    route: candidate,
                    body: change,
                    idempotencyKey: key,
                    userPresence: presence
                )
            }
        } catch {
            guard (error as? APIError)?.code == "USER_PRESENCE_NOT_REGISTERED" else { throw error }
        }
        try await enrollPresenceKey()
        let retryPresence = try await userPresenceAuthorizer.authorize(localizedReason: reason)
        return try await performRemoteRequest { candidate in
            try await runtime.configureRemoteOverlay(
                route: candidate,
                body: change,
                idempotencyKey: key,
                userPresence: retryPresence
            )
        }
    }
}
