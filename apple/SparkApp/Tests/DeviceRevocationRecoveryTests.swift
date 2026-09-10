import Foundation
import SparkAPI
import SparkCore
import SparkLibrary
import SparkSecurity
import Testing
@testable import SparkAppComposition

@MainActor
@Test func failedRevocationRetryReusesItsIdempotencyKey() async throws {
    let tablet = deviceManagementTestPairedDevice(
        id: "tablet",
        name: "Studio iPad",
        platform: .ipados,
        role: .user
    )
    let provider = DeviceManagementTestDeviceManagementStub(
        devices: [tablet],
        revokeErrors: [
            tablet.id: APIError(.local(message: "Connection lost."), code: "OFFLINE")
        ]
    )
    let presence = DeviceManagementTestTestPresenceAuthorizer()
    let model = DeviceManagementModel(
        route: deviceManagementTestDeviceManagementRoute,
        provider: provider,
        userPresenceAuthorizer: presence
    )
    await model.refresh()

    model.requestRevocation(deviceID: tablet.id)
    await model.confirmRevocation()
    await provider.setRevokeError(nil, for: tablet.id)
    await model.retryFailedRevocation()

    let calls = await provider.calls()
    #expect(calls.count == 2)
    #expect(calls[0].deviceID == tablet.id)
    #expect(calls[0].idempotencyKey == calls[1].idempotencyKey)
    #expect(calls[0].presencePublicKeySPKI == calls[1].presencePublicKeySPKI)
    #expect(calls[0].authorizationID != calls[1].authorizationID)
    #expect(await presence.authorizationCount == 2)
    #expect(model.devices.first?.revoked == true)
    #expect(model.failedRevocation == nil)
}

@MainActor
@Test func definitiveRejectionMintsANewIdempotencyKeyForRetry() async throws {
    let tablet = deviceManagementTestPairedDevice(
        id: "tablet",
        name: "Studio iPad",
        platform: .ipados,
        role: .user
    )
    let provider = DeviceManagementTestDeviceManagementStub(
        devices: [tablet],
        revokeErrors: [
            tablet.id: APIError(.local(message: "Conflict."), statusCode: 409, code: "CONFLICT")
        ]
    )
    let model = DeviceManagementModel(
        route: deviceManagementTestDeviceManagementRoute,
        provider: provider,
        userPresenceAuthorizer: DeviceManagementTestTestPresenceAuthorizer()
    )
    await model.refresh()

    model.requestRevocation(deviceID: tablet.id)
    await model.confirmRevocation()
    await provider.setRevokeError(nil, for: tablet.id)
    await model.retryFailedRevocation()

    let calls = await provider.calls()
    #expect(calls.count == 2)
    #expect(calls[0].idempotencyKey != calls[1].idempotencyKey)
}

@MainActor
@Test func legacyGrantEnrollsPresenceThenRetriesWithFreshProofAndKey() async throws {
    let tablet = deviceManagementTestPairedDevice(
        id: "tablet",
        name: "Studio iPad",
        platform: .ipados,
        role: .user
    )
    let provider = DeviceManagementTestDeviceManagementStub(
        devices: [tablet],
        revokeErrors: [
            tablet.id: APIError(
                .local(message: "Presence key is not registered."),
                statusCode: 403,
                code: "USER_PRESENCE_NOT_REGISTERED"
            )
        ]
    )
    let presence = DeviceManagementTestTestPresenceAuthorizer()
    let model = DeviceManagementModel(
        route: deviceManagementTestDeviceManagementRoute,
        provider: provider,
        userPresenceAuthorizer: presence
    )
    await model.refresh()

    model.requestRevocation(deviceID: tablet.id)
    await model.confirmRevocation()

    let calls = await provider.calls()
    let enrollments = await provider.enrollments()
    #expect(calls.count == 2)
    #expect(enrollments.count == 1)
    #expect(calls[0].idempotencyKey != calls[1].idempotencyKey)
    #expect(calls[0].authorizationID != calls[1].authorizationID)
    #expect(await presence.authorizationCount == 3)
    #expect(model.devices.first?.revoked == true)
    #expect(model.revocationErrorMessage == nil)
}

@MainActor
@Test func ambiguousLegacyEnrollmentRetryReusesItsIdempotencyKey() async throws {
    let tablet = deviceManagementTestPairedDevice(
        id: "tablet",
        name: "Studio iPad",
        platform: .ipados,
        role: .user
    )
    let notRegistered = APIError(
        .local(message: "Presence key is not registered."),
        statusCode: 403,
        code: "USER_PRESENCE_NOT_REGISTERED"
    )
    let provider = DeviceManagementTestDeviceManagementStub(
        devices: [tablet],
        revokeErrors: [tablet.id: notRegistered],
        enrollmentError: APIError(.local(message: "Connection lost."), code: "OFFLINE")
    )
    let model = DeviceManagementModel(
        route: deviceManagementTestDeviceManagementRoute,
        provider: provider,
        userPresenceAuthorizer: DeviceManagementTestTestPresenceAuthorizer()
    )
    await model.refresh()

    model.requestRevocation(deviceID: tablet.id)
    await model.confirmRevocation()
    await provider.setRevokeError(notRegistered, for: tablet.id)
    await provider.setEnrollmentError(nil)
    await model.retryFailedRevocation()

    let enrollments = await provider.enrollments()
    #expect(enrollments.count == 2)
    #expect(enrollments[0].idempotencyKey == enrollments[1].idempotencyKey)
    #expect(model.devices.first?.revoked == true)
}

@MainActor
@Test func refreshReconcilesAConfirmedOptimisticRevocation() async throws {
    let tablet = deviceManagementTestPairedDevice(
        id: "tablet",
        name: "Studio iPad",
        platform: .ipados,
        role: .user
    )
    let provider = DeviceManagementTestDeviceManagementStub(devices: [tablet])
    let model = DeviceManagementModel(
        route: deviceManagementTestDeviceManagementRoute,
        provider: provider,
        userPresenceAuthorizer: DeviceManagementTestTestPresenceAuthorizer()
    )
    await model.refresh()
    await provider.setListError(
        APIError(.local(message: "Connection lost."), code: "OFFLINE")
    )

    model.requestRevocation(deviceID: tablet.id)
    await model.confirmRevocation()

    #expect(model.devices == [tablet])
    #expect(model.displayedDevices.isEmpty)
    #expect(model.optimisticRevocationDeviceIDs == [tablet.id])
    #expect(model.failedRevocation?.device.id == tablet.id)
    #expect(model.revocationErrorMessage?.contains("accepted the revocation") == true)

    await provider.setListError(nil)
    await model.refresh()

    #expect(model.devices.first?.revoked == true)
    #expect(model.optimisticRevocationDeviceIDs.isEmpty)
    #expect(model.failedRevocation == nil)
    #expect(model.revocationErrorMessage == nil)
}
