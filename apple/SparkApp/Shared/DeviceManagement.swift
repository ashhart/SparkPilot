import Foundation
import Observation
import SparkAPI
import SparkSecurity

public protocol DeviceManagementProviding: Sendable {
    func devices(route: URL) async throws -> [GeneratedAPI.Device]
    func revokeDevice(
        route: URL,
        deviceID: String,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws
    func enrollPresenceKey(
        route: URL,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws -> String
}

extension DeviceManagementProviding {
    public func enrollPresenceKey(
        route: URL,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws -> String {
        throw APIError(
            .local(message: String(localized: "Presence-key enrollment is unavailable.")),
            code: "USER_PRESENCE_ENROLLMENT_UNAVAILABLE"
        )
    }
}

extension SparkAPIClient: DeviceManagementProviding {}

public enum DeviceListFreshness: Sendable, Equatable {
    case notLoaded
    case current(refreshedAt: Date)
    case cached(refreshedAt: Date)
    case unavailable
}

public struct DeviceListCacheEntry: Codable, Equatable, Sendable {
    public let devices: [GeneratedAPI.Device]
    public let refreshedAt: Date

    public init(devices: [GeneratedAPI.Device], refreshedAt: Date) {
        self.devices = devices
        self.refreshedAt = refreshedAt
    }
}

public protocol DeviceListCacheStoring: Sendable {
    func load(targetID: String) throws -> DeviceListCacheEntry?
    func save(_ entry: DeviceListCacheEntry, targetID: String) throws
}

/// Caches non-secret paired-device metadata for reconnection while treating Spark grants as authoritative.
public struct UserDefaultsDeviceListCacheStore: DeviceListCacheStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let keyPrefix: String

    public init(
        defaults: UserDefaults = .standard,
        keyPrefix: String = "sparkpilot.device-list-cache.v1."
    ) {
        self.defaults = defaults
        self.keyPrefix = keyPrefix
    }

    public func load(targetID: String) throws -> DeviceListCacheEntry? {
        guard let data = defaults.data(forKey: cacheKey(targetID)) else { return nil }
        return try JSONDecoder().decode(DeviceListCacheEntry.self, from: data)
    }

    public func save(_ entry: DeviceListCacheEntry, targetID: String) throws {
        defaults.set(try JSONEncoder().encode(entry), forKey: cacheKey(targetID))
    }

    private func cacheKey(_ targetID: String) -> String {
        keyPrefix + Data(targetID.utf8).base64EncodedString()
    }
}

public struct DeviceRevocationRequest: Sendable, Equatable, Identifiable {
    public let device: GeneratedAPI.Device

    public var id: String { device.id }

    public init(device: GeneratedAPI.Device) {
        self.device = device
    }
}

@MainActor
@Observable
public final class DeviceManagementModel {
    public private(set) var devices: [GeneratedAPI.Device] = []
    public private(set) var optimisticRevocationDeviceIDs: Set<String> = []
    public private(set) var freshness: DeviceListFreshness = .notLoaded
    public private(set) var hasLoaded = false
    public private(set) var isRefreshing = false
    public private(set) var revokingDeviceID: String?
    public private(set) var readErrorMessage: String?
    public private(set) var revocationErrorMessage: String?
    public private(set) var revocationConfirmation: DeviceRevocationRequest?
    public private(set) var failedRevocation: DeviceRevocationRequest?
    /// Reports the key protection used for the most recent successful local approval.
    public private(set) var userPresenceProtection: UserPresenceKeyProtection?

    public let route: URL
    public let targetID: String
    public let localDeviceID: String?

    public var trustedDevices: [GeneratedAPI.Device] {
        devices.filter { !$0.revoked && !optimisticRevocationDeviceIDs.contains($0.id) }
    }

    public var displayedDevices: [GeneratedAPI.Device] {
        devices.filter { !optimisticRevocationDeviceIDs.contains($0.id) }
    }

    public var localDeviceRole: GeneratedAPI.Role? {
        guard let localDeviceID else { return nil }
        return trustedDevices.first { $0.id.caseInsensitiveCompare(localDeviceID) == .orderedSame }?
            .role
    }

    @ObservationIgnored
    private let provider: any DeviceManagementProviding
    @ObservationIgnored
    private let userPresenceAuthorizer: any UserPresenceAuthorizing
    @ObservationIgnored
    private let now: @Sendable () -> Date
    @ObservationIgnored
    private let cacheStore: any DeviceListCacheStoring
    @ObservationIgnored
    private let onLocalDeviceRoleResolved: @MainActor (GeneratedAPI.Role?) -> Void
    @ObservationIgnored
    private var lastSuccessfulRefresh: Date?
    @ObservationIgnored
    private var revocationKeys: [String: UUID] = [:]
    @ObservationIgnored
    private var presenceEnrollmentKey: UUID?

    public init(
        route: URL,
        targetID: String? = nil,
        localDeviceID: String? = nil,
        provider: any DeviceManagementProviding,
        userPresenceAuthorizer: any UserPresenceAuthorizing,
        cacheStore: any DeviceListCacheStoring = UserDefaultsDeviceListCacheStore(),
        onLocalDeviceRoleResolved: @escaping @MainActor (GeneratedAPI.Role?) -> Void = { _ in },
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.route = route
        self.targetID = targetID ?? route.absoluteString
        self.localDeviceID = localDeviceID
        self.provider = provider
        self.userPresenceAuthorizer = userPresenceAuthorizer
        self.cacheStore = cacheStore
        self.onLocalDeviceRoleResolved = onLocalDeviceRoleResolved
        self.now = now
        if let cached = try? cacheStore.load(targetID: self.targetID) {
            devices = cached.devices
            lastSuccessfulRefresh = cached.refreshedAt
            freshness = .cached(refreshedAt: cached.refreshedAt)
        }
    }

    public func loadIfNeeded() async {
        guard !hasLoaded else { return }
        await refresh()
    }

    public func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        readErrorMessage = nil
        defer {
            isRefreshing = false
            hasLoaded = true
        }

        do {
            devices = try await provider.devices(route: route)
            let refreshedAt = now()
            lastSuccessfulRefresh = refreshedAt
            freshness = .current(refreshedAt: refreshedAt)
            optimisticRevocationDeviceIDs.removeAll()
            saveCache(refreshedAt: refreshedAt)
            reconcileFailedRevocation()
            onLocalDeviceRoleResolved(localDeviceRole)
        } catch {
            freshness = lastSuccessfulRefresh.map(DeviceListFreshness.cached) ?? .unavailable
            readErrorMessage = Self.readFailureMessage(for: error)
        }
    }

    public func requestRevocation(deviceID: String) {
        guard !isRefreshing,
            revokingDeviceID == nil,
            let device = devices.first(where: { $0.id == deviceID }),
            !device.revoked
        else { return }

        revocationErrorMessage = nil
        failedRevocation = nil
        revocationConfirmation = DeviceRevocationRequest(device: device)
    }

    public func cancelRevocationConfirmation() {
        revocationConfirmation = nil
    }

    public func confirmRevocation() async {
        guard let request = revocationConfirmation else { return }
        revocationConfirmation = nil
        await revoke(request)
    }

    public func retryFailedRevocation() async {
        guard let request = failedRevocation else { return }
        await revoke(request)
    }

    public func dismissRevocationError() {
        revocationErrorMessage = nil
        failedRevocation = nil
    }

    private func revoke(_ request: DeviceRevocationRequest) async {
        guard revokingDeviceID == nil else { return }
        let deviceID = request.device.id
        let idempotencyKey = revocationKeys[deviceID] ?? UUID()
        revocationKeys[deviceID] = idempotencyKey
        revokingDeviceID = deviceID
        revocationErrorMessage = nil
        failedRevocation = nil
        defer { revokingDeviceID = nil }

        let userPresence: any UserPresenceProofSigning
        do {
            userPresence = try await userPresenceAuthorizer.authorize(
                localizedReason: String(
                    localized: .confirmRevokingAccess(request.device.displayName)
                )
            )
            userPresenceProtection = userPresence.keyInfo.protection
        } catch {
            failedRevocation = request
            revocationErrorMessage = Self.userPresenceFailureMessage(for: error)
            return
        }

        optimisticRevocationDeviceIDs.insert(deviceID)

        do {
            try await provider.revokeDevice(
                route: route,
                deviceID: deviceID,
                idempotencyKey: idempotencyKey,
                userPresence: userPresence
            )
        } catch {
            if (error as? APIError)?.code == "USER_PRESENCE_NOT_REGISTERED" {
                revocationKeys.removeValue(forKey: deviceID)
                do {
                    try await enrollPresenceKeyAndRetryRevocation(request)
                } catch {
                    optimisticRevocationDeviceIDs.remove(deviceID)
                    failedRevocation = request
                    if error is UserPresenceAuthorizationError {
                        revocationErrorMessage = Self.userPresenceFailureMessage(for: error)
                    } else {
                        revocationErrorMessage = Self.revocationFailureMessage(for: error)
                    }
                    return
                }
            } else {
                optimisticRevocationDeviceIDs.remove(deviceID)
                failedRevocation = request
                revocationErrorMessage = Self.revocationFailureMessage(for: error)
                if Self.isDefinitiveRejection(error) {
                    revocationKeys.removeValue(forKey: deviceID)
                }
                return
            }
        }

        presenceEnrollmentKey = nil

        do {
            // Reconcile revocation only from the next authenticated device list, including recovery after a lost response.
            let refreshedDevices = try await provider.devices(route: route)
            devices = refreshedDevices
            let refreshedAt = now()
            lastSuccessfulRefresh = refreshedAt
            freshness = .current(refreshedAt: refreshedAt)
            readErrorMessage = nil
            optimisticRevocationDeviceIDs.remove(deviceID)
            saveCache(refreshedAt: refreshedAt)
            revocationKeys.removeValue(forKey: deviceID)
            onLocalDeviceRoleResolved(localDeviceRole)
        } catch {
            failedRevocation = request
            freshness = lastSuccessfulRefresh.map(DeviceListFreshness.cached) ?? .unavailable
            revocationErrorMessage = Self.revocationRefreshFailureMessage(for: error)
        }
    }

    private func enrollPresenceKeyAndRetryRevocation(
        _ request: DeviceRevocationRequest
    ) async throws {
        let enrollmentSession = try await userPresenceAuthorizer.authorize(
            localizedReason:
                String(localized: "Confirm upgrading protected actions for this Apple device.")
        )
        userPresenceProtection = enrollmentSession.keyInfo.protection
        let enrollmentKey = presenceEnrollmentKey ?? UUID()
        presenceEnrollmentKey = enrollmentKey
        do {
            _ = try await provider.enrollPresenceKey(
                route: route,
                idempotencyKey: enrollmentKey,
                userPresence: enrollmentSession
            )
            presenceEnrollmentKey = nil
        } catch {
            if Self.isDefinitiveRejection(error) { presenceEnrollmentKey = nil }
            throw error
        }

        let retrySession = try await userPresenceAuthorizer.authorize(
            localizedReason: String(
                localized: .confirmRevokingAccess(request.device.displayName)
            )
        )
        userPresenceProtection = retrySession.keyInfo.protection
        let retryKey = UUID()
        revocationKeys[request.device.id] = retryKey
        do {
            try await provider.revokeDevice(
                route: route,
                deviceID: request.device.id,
                idempotencyKey: retryKey,
                userPresence: retrySession
            )
        } catch {
            if Self.isDefinitiveRejection(error) {
                revocationKeys.removeValue(forKey: request.device.id)
            }
            throw error
        }
    }

    private func reconcileFailedRevocation() {
        guard let failedRevocation else { return }
        let device = devices.first { $0.id == failedRevocation.device.id }
        guard device == nil || device?.revoked == true else { return }
        revocationErrorMessage = nil
        self.failedRevocation = nil
        revocationKeys.removeValue(forKey: failedRevocation.device.id)
    }

    private func saveCache(refreshedAt: Date) {
        try? cacheStore.save(
            DeviceListCacheEntry(devices: devices, refreshedAt: refreshedAt),
            targetID: targetID
        )
    }

    private static func readFailureMessage(for error: Error) -> String {
        let detail = errorDetail(error)
        return detail.isEmpty
            ? String(
                localized:
                    "The device list could not be refreshed. Cached devices remain unchanged."
            )
            : String(localized: .deviceListNotRefreshed(detail))
    }

    private static func revocationFailureMessage(for error: Error) -> String {
        let detail = errorDetail(error)
        return detail.isEmpty
            ? String(
                localized:
                    "The Spark did not confirm the revocation. No device was removed from this list."
            )
            : String(localized: .revocationNotConfirmed(detail))
    }

    private static func isDefinitiveRejection(_ error: Error) -> Bool {
        guard let status = (error as? APIError)?.statusCode else { return false }
        return (400...499).contains(status)
    }

    private static func userPresenceFailureMessage(for error: Error) -> String {
        switch error as? UserPresenceAuthorizationError {
        case .declined:
            return
                String(
                    localized:
                        "Revocation was cancelled. Confirm with Face ID, Touch ID, or your device passcode to try again."
                )
        case .unavailable:
            return
                String(
                    localized:
                        "This Apple device cannot confirm user presence. Set up Face ID, Touch ID, or a device passcode, then try again."
                )
        case .keyUnavailable:
            return
                String(
                    localized:
                        "This Apple device could not use its presence key. Unlock the device and try again."
                )
        case nil:
            return
                String(
                    localized:
                        "This Apple device could not confirm user presence. No revocation request was sent."
                )
        }
    }

    private static func revocationRefreshFailureMessage(for error: Error) -> String {
        let detail = errorDetail(error)
        let message =
            String(
                localized:
                    "The Spark accepted the revocation. The device remains hidden while SparkPilot retries verification."
            )
        return detail.isEmpty
            ? message
            : String(localized: .sentencePair(message, detail))
    }

    private static func errorDetail(_ error: Error) -> String {
        if let apiError = error as? APIError { return APIError.message(for: apiError) }
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return ""
    }
}
