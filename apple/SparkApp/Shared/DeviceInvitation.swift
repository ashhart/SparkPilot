import Foundation
import Observation
import SparkAPI
import SparkBootstrap
import SparkDesignSystem
import SparkSecurity
import SwiftUI

/// Offers invitation roles by management capability while leaving the full runtime role set available for later editing.
public enum InvitedDeviceRole: String, CaseIterable, Sendable, Identifiable {
    case administrator
    case user

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .administrator: String(localized: "Manage this Spark")
        case .user: String(localized: "Use this Spark")
        }
    }

    public var detail: String {
        switch self {
        case .administrator:
            return String(
                localized: "Models, updates, networking, and other devices. Not ownership transfer."
            )
        case .user:
            return String(
                localized: "Chat and use installed models. No changes to the Spark itself."
            )
        }
    }
}

/// Presents a five-minute single-use signed invitation with the TLS pin and authority public key needed to verify the new Spark.
@MainActor
@Observable
public final class DeviceInvitationModel {
    public private(set) var payload: String?
    public private(set) var joinCode: String?
    public private(set) var expiresAt: Date?
    public private(set) var errorMessage: String?
    public private(set) var isCreating = false
    public private(set) var isConfirmingAdministrator = false
    public var role: InvitedDeviceRole = .administrator {
        didSet {
            guard allowedRoles.contains(role) else {
                role = oldValue
                return
            }
            guard role != oldValue else { return }
            payload = nil
            joinCode = nil
            expiresAt = nil
            errorMessage = nil
            isConfirmingAdministrator = false
            invitationKey = nil
        }
    }

    public var tlsFingerprint: String { trust.tlsFingerprint }

    public let nodeName: String
    public let allowedRoles: [InvitedDeviceRole]

    @ObservationIgnored
    private let route: URL
    @ObservationIgnored
    private let trust: NodeTrust
    @ObservationIgnored
    private let runtime: any SparkRuntimeReading
    @ObservationIgnored
    private let now: @Sendable () -> Date
    @ObservationIgnored
    private let userPresenceAuthorizer: any UserPresenceAuthorizing
    @ObservationIgnored
    private let presenceEnrollmentProvider: (any DeviceManagementProviding)?
    @ObservationIgnored
    private var presenceEnrollmentKey: UUID?
    @ObservationIgnored
    private var invitationKey: UUID?

    public init(
        route: URL,
        trust: NodeTrust,
        runtime: any SparkRuntimeReading,
        allowedRoles: [InvitedDeviceRole] = InvitedDeviceRole.allCases,
        userPresenceAuthorizer: any UserPresenceAuthorizing = SystemUserPresenceAuthorizer(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.route = route
        self.trust = trust
        self.runtime = runtime
        let roles = allowedRoles.isEmpty ? [.user] : allowedRoles
        self.allowedRoles = roles
        self.role = roles[0]
        self.userPresenceAuthorizer = userPresenceAuthorizer
        self.presenceEnrollmentProvider = runtime as? any DeviceManagementProviding
        self.now = now
        self.nodeName = trust.nodeName
    }

    /// Whether the invitation on screen is still worth scanning.
    public var isExpired: Bool {
        guard let expiresAt else { return false }
        return expiresAt <= now()
    }

    public func requestInvitation() async {
        guard role != .administrator else {
            isConfirmingAdministrator = true
            return
        }
        await createInvitation(for: .user)
    }

    public func cancelAdministratorConfirmation() {
        isConfirmingAdministrator = false
    }

    public func confirmAdministratorInvitation() async {
        guard role == .administrator else {
            isConfirmingAdministrator = false
            return
        }
        isConfirmingAdministrator = false
        await createInvitation(for: .administrator)
    }

    private func createInvitation(for requestedRole: InvitedDeviceRole) async {
        guard !isCreating else { return }
        isCreating = true
        errorMessage = nil
        defer { isCreating = false }

        let idempotencyKey = invitationKey ?? UUID()
        invitationKey = idempotencyKey
        do {
            let invitation = try await issueInvitation(
                for: requestedRole,
                idempotencyKey: idempotencyKey
            )
            guard invitation.nodeID.lowercased() == trust.nodeID.lowercased() else {
                // Reject invitations returned by a node other than the paired identity.
                payload = nil
                joinCode = nil
                expiresAt = nil
                errorMessage =
                    String(
                        localized:
                            "This Spark returned an invitation for a different Spark. Nothing was shared."
                    )
                invitationKey = nil
                return
            }
            let package = AdditionalDevicePairingPackage(
                nodeName: trust.nodeName,
                tlsFingerprint: trust.tlsFingerprint,
                authorityPublicKey: trust.authorityPublicKey,
                invitation: invitation,
                localHint: route.absoluteString
            )
            payload = try package.qrPayload()
            joinCode = invitation.joinCode
            // Parse fractional runtime timestamps so expired invitations cannot leave a usable-looking QR code.
            expiresAt = RFC3339.date(from: invitation.expiresAt)
            invitationKey = nil
        } catch {
            payload = nil
            joinCode = nil
            expiresAt = nil
            errorMessage = Self.describe(error)
            if Self.isDefinitiveRejection(error) { invitationKey = nil }
        }
    }

    private func issueInvitation(
        for requestedRole: InvitedDeviceRole,
        idempotencyKey: UUID
    ) async throws
        -> PairingInvitation
    {
        guard requestedRole == .administrator else {
            return try await runtime.createPairingInvitation(
                route: route,
                role: requestedRole.rawValue,
                expiresInSeconds: 300,
                deviceNameHint: nil,
                idempotencyKey: idempotencyKey,
                userPresence: nil
            )
        }

        let session = try await userPresenceAuthorizer.authorize(
            localizedReason: String(
                localized: "Confirm adding a device that can manage this Spark."
            )
        )
        do {
            return try await runtime.createPairingInvitation(
                route: route,
                role: requestedRole.rawValue,
                expiresInSeconds: 300,
                deviceNameHint: nil,
                idempotencyKey: idempotencyKey,
                userPresence: session
            )
        } catch {
            guard (error as? APIError)?.code == "USER_PRESENCE_NOT_REGISTERED" else {
                throw error
            }
        }

        try await enrollPresenceKey()
        let retrySession = try await userPresenceAuthorizer.authorize(
            localizedReason: String(
                localized: "Confirm adding a device that can manage this Spark."
            )
        )
        return try await runtime.createPairingInvitation(
            route: route,
            role: requestedRole.rawValue,
            expiresInSeconds: 300,
            deviceNameHint: nil,
            idempotencyKey: idempotencyKey,
            userPresence: retrySession
        )
    }

    private func enrollPresenceKey() async throws {
        guard let presenceEnrollmentProvider else {
            throw APIError(
                .local(
                    message: String(
                        localized: "This Spark cannot upgrade protected actions from this device."
                    )
                ),
                code: "USER_PRESENCE_ENROLLMENT_UNAVAILABLE"
            )
        }
        let session = try await userPresenceAuthorizer.authorize(
            localizedReason: String(
                localized: "Confirm upgrading protected actions for this Apple device."
            )
        )
        let idempotencyKey = presenceEnrollmentKey ?? UUID()
        presenceEnrollmentKey = idempotencyKey
        do {
            _ = try await presenceEnrollmentProvider.enrollPresenceKey(
                route: route,
                idempotencyKey: idempotencyKey,
                userPresence: session
            )
            presenceEnrollmentKey = nil
        } catch {
            if Self.isDefinitiveRejection(error) { presenceEnrollmentKey = nil }
            throw error
        }
    }

    private static func isDefinitiveRejection(_ error: Error) -> Bool {
        guard let status = (error as? APIError)?.statusCode else { return false }
        return (400...499).contains(status)
    }

    static func describe(_ error: any Error) -> String {
        if error is UserPresenceAuthorizationError {
            return
                String(
                    localized:
                        "This Apple device could not confirm you are present. No invitation was created."
                )
        }
        if error is AdditionalDevicePairingPackageError {
            return
                String(
                    localized: """
                        This device could not build a safe invitation from what the Spark \
                        returned. Nothing was shared.
                        """
                )
        }
        guard let api = error as? APIError else {
            return String(
                localized:
                    "The invitation could not be created. Check the connection and try again."
            )
        }
        switch api.code {
        case "USER_PRESENCE_REQUIRED", "USER_PRESENCE_INVALID", "USER_PRESENCE_EXPIRED",
            "USER_PRESENCE_NOT_REGISTERED", "USER_PRESENCE_SIGNER_UNAVAILABLE",
            "USER_PRESENCE_ENROLLMENT_UNAVAILABLE":
            return
                String(
                    localized:
                        "This Apple device could not confirm you are present. No invitation was created."
                )
        default:
            break
        }
        switch api.statusCode {
        case 401, 403:
            return
                String(
                    localized: """
                        This device is not allowed to invite others to this Spark. Ask an \
                        owner or administrator device to create the invitation.
                        """
                )
        case 404:
            return String(localized: "This Spark's software does not offer device invitations yet.")
        case 409:
            // Explain second-owner invitation refusal without implying a network or Spark fault.
            return
                String(
                    localized: """
                        This Spark already has an owner, so it will not issue another owner \
                        invitation. Choose what the new device may do and try again.
                        """
                )
        default:
            return APIError.message(for: api)
        }
    }
}
