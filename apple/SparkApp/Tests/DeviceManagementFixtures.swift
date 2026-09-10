import Foundation
import SparkAPI
import SparkCore
import SparkLibrary
import SparkSecurity
import Testing
@testable import SparkAppComposition

actor DeviceManagementTestDeviceManagementStub: DeviceManagementProviding {
    private var currentDevices: [GeneratedAPI.Device]
    private var listError: APIError?
    private var revokeErrors: [String: APIError]
    private var enrollmentError: APIError?
    private(set) var revokeCalls:
        [(
            deviceID: String,
            idempotencyKey: UUID,
            presencePublicKeySPKI: Data,
            authorizationID: UUID?
        )] = []
    private(set) var enrollmentCalls: [(idempotencyKey: UUID, presencePublicKeySPKI: Data)] = []
    private(set) var listCallCount = 0

    init(
        devices: [GeneratedAPI.Device],
        revokeErrors: [String: APIError] = [:],
        enrollmentError: APIError? = nil
    ) {
        self.currentDevices = devices
        self.revokeErrors = revokeErrors
        self.enrollmentError = enrollmentError
    }

    func devices(route: URL) async throws -> [GeneratedAPI.Device] {
        listCallCount += 1
        if let listError { throw listError }
        return currentDevices
    }

    func revokeDevice(
        route: URL,
        deviceID: String,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws {
        revokeCalls.append(
            (
                deviceID,
                idempotencyKey,
                userPresence.keyInfo.publicKeySPKI,
                (userPresence as? DeviceManagementTestTestPresenceSession)?.authorizationID
            )
        )
        if let error = revokeErrors.removeValue(forKey: deviceID) { throw error }
        guard let index = currentDevices.firstIndex(where: { $0.id == deviceID }) else { return }
        currentDevices[index].revoked = true
    }

    func enrollPresenceKey(
        route: URL,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws -> String {
        enrollmentCalls.append((idempotencyKey, userPresence.keyInfo.publicKeySPKI))
        if let enrollmentError { throw enrollmentError }
        return try userPresence.keyInfo.pairingFingerprint()
    }

    func setListError(_ error: APIError?) {
        listError = error
    }

    func setRevokeError(_ error: APIError?, for deviceID: String) {
        revokeErrors[deviceID] = error
    }

    func setEnrollmentError(_ error: APIError?) {
        enrollmentError = error
    }

    func calls() -> [(
        deviceID: String,
        idempotencyKey: UUID,
        presencePublicKeySPKI: Data,
        authorizationID: UUID?
    )] {
        revokeCalls
    }

    func enrollments() -> [(idempotencyKey: UUID, presencePublicKeySPKI: Data)] {
        enrollmentCalls
    }
}

final class DeviceManagementTestTestPresenceSession: UserPresenceProofSigning, @unchecked Sendable {
    let authorizationID = UUID()
    let keyInfo: UserPresenceKeyInfo
    private let signer: SoftwareSigner

    init(signer: SoftwareSigner) {
        self.signer = signer
        self.keyInfo = UserPresenceKeyInfo(
            publicKeySPKI: signer.publicKeySPKI,
            protection: .softwareTestOnly
        )
    }

    func proof(for request: UserPresenceCanonicalRequest) async throws -> UserPresenceProof {
        try UserPresenceProof.sign(request) { try signer.sign($0) }
    }
}

actor DeviceManagementTestTestPresenceAuthorizer: UserPresenceAuthorizing {
    enum Outcome {
        case approve
        case decline
        case unavailable
    }

    private var outcome: Outcome
    private let signer = SoftwareSigner()
    private(set) var authorizationCount = 0

    init(outcome: Outcome = .approve) {
        self.outcome = outcome
    }

    func keyInfo() async throws -> UserPresenceKeyInfo {
        UserPresenceKeyInfo(
            publicKeySPKI: signer.publicKeySPKI,
            protection: .softwareTestOnly
        )
    }

    func authorize(localizedReason: String) async throws -> any UserPresenceProofSigning {
        authorizationCount += 1
        switch outcome {
        case .approve:
            return DeviceManagementTestTestPresenceSession(signer: signer)
        case .decline:
            throw UserPresenceAuthorizationError.declined
        case .unavailable:
            throw UserPresenceAuthorizationError.unavailable
        }
    }

    func setOutcome(_ outcome: Outcome) {
        self.outcome = outcome
    }
}

let deviceManagementTestDeviceManagementRoute = URL(string: "https://spark.local:7443")!

let deviceManagementTestDeviceManagementDate = Date(timeIntervalSince1970: 1_777_374_000)

final class DeviceManagementTestInMemoryDeviceListCache: DeviceListCacheStoring, @unchecked Sendable
{
    private var entries: [String: DeviceListCacheEntry] = [:]
    private let lock = NSLock()

    func load(targetID: String) throws -> DeviceListCacheEntry? {
        lock.withLock { entries[targetID] }
    }

    func save(_ entry: DeviceListCacheEntry, targetID: String) throws {
        lock.withLock { entries[targetID] = entry }
    }
}

func deviceManagementTestPairedDevice(
    id: String,
    name: String,
    platform: GeneratedAPI.DevicePlatform,
    role: GeneratedAPI.Role,
    revoked: Bool = false
) -> GeneratedAPI.Device {
    GeneratedAPI.Device(
        id: id,
        displayName: name,
        platform: platform,
        role: role,
        capabilities: ["models.read"],
        pairedAt: "2026-08-20T09:30:00Z",
        lastSeenAt: "2026-08-28T11:45:00Z",
        revoked: revoked
    )
}
