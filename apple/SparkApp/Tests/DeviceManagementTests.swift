import Foundation
import SparkAPI
import SparkCore
import SparkLibrary
import SparkSecurity
import Testing
@testable import SparkAppComposition

@Test func devicePrimaryActionsHaveSpecificAccessibilityLabels() {
    #expect(
        DeviceManagementActionPresentation.refreshAccessibilityLabel
            == "Refresh paired devices"
    )
    #expect(
        DeviceManagementActionPresentation.retryAccessibilityLabel
            == "Retry loading paired devices"
    )
    #expect(
        DeviceManagementActionPresentation.retryRevocationAccessibilityLabel
            == "Retry device revocation"
    )
    #expect(
        DeviceManagementActionPresentation.revokeAccessibilityLabel(
            deviceName: "Studio iPad",
            isRevoking: false
        ) == "Revoke access for Studio iPad"
    )
    #expect(
        DeviceManagementActionPresentation.revokeAccessibilityLabel(
            deviceName: "Studio iPad",
            isRevoking: true
        ) == "Revoking access for Studio iPad"
    )
}

@MainActor
@Test func pairedDeviceCacheSurvivesRelaunchAndRefreshesInTheBackground() async {
    let owner = deviceManagementTestPairedDevice(
        id: "owner",
        name: "Alex's iPhone",
        platform: .ios,
        role: .owner
    )
    let cache = DeviceManagementTestInMemoryDeviceListCache()
    let onlineProvider = DeviceManagementTestDeviceManagementStub(devices: [owner])
    let firstModel = DeviceManagementModel(
        route: deviceManagementTestDeviceManagementRoute,
        targetID: "node:cached",
        provider: onlineProvider,
        userPresenceAuthorizer: DeviceManagementTestTestPresenceAuthorizer(),
        cacheStore: cache,
        now: { deviceManagementTestDeviceManagementDate }
    )
    await firstModel.refresh()

    let offlineProvider = DeviceManagementTestDeviceManagementStub(devices: [])
    await offlineProvider.setListError(
        APIError(.local(message: "The Spark is offline."), code: "OFFLINE")
    )
    let relaunchedModel = DeviceManagementModel(
        route: deviceManagementTestDeviceManagementRoute,
        targetID: "node:cached",
        provider: offlineProvider,
        userPresenceAuthorizer: DeviceManagementTestTestPresenceAuthorizer(),
        cacheStore: cache
    )

    #expect(relaunchedModel.devices == [owner])
    #expect(
        relaunchedModel.freshness == .cached(refreshedAt: deviceManagementTestDeviceManagementDate)
    )
    #expect(!relaunchedModel.hasLoaded)

    await relaunchedModel.loadIfNeeded()

    #expect(relaunchedModel.devices == [owner])
    #expect(relaunchedModel.readErrorMessage?.contains("Cached devices") == true)
}

@MainActor
@Test func revocationRequiresConfirmationAndKeepsOtherDevicesTrusted() async throws {
    let owner = deviceManagementTestPairedDevice(
        id: "owner",
        name: "Alex's iPhone",
        platform: .ios,
        role: .owner
    )
    let tablet = deviceManagementTestPairedDevice(
        id: "tablet",
        name: "Studio iPad",
        platform: .ipados,
        role: .user
    )
    let mac = deviceManagementTestPairedDevice(
        id: "mac",
        name: "Desk Mac",
        platform: .macos,
        role: .developer
    )
    let provider = DeviceManagementTestDeviceManagementStub(devices: [owner, tablet, mac])
    let model = DeviceManagementModel(
        route: deviceManagementTestDeviceManagementRoute,
        localDeviceID: owner.id,
        provider: provider,
        userPresenceAuthorizer: DeviceManagementTestTestPresenceAuthorizer(),
        now: { deviceManagementTestDeviceManagementDate }
    )
    await model.refresh()

    model.requestRevocation(deviceID: tablet.id)

    #expect(model.revocationConfirmation?.device.id == tablet.id)
    #expect(await provider.calls().isEmpty)
    #expect(model.devices.allSatisfy { !$0.revoked })

    await model.confirmRevocation()

    #expect(model.devices.count == 3)
    #expect(model.devices.first(where: { $0.id == tablet.id })?.revoked == true)
    #expect(model.devices.first(where: { $0.id == owner.id })?.revoked == false)
    #expect(model.devices.first(where: { $0.id == mac.id })?.revoked == false)
    #expect(Set(model.trustedDevices.map(\.id)) == Set([owner.id, mac.id]))
    #expect(model.revocationErrorMessage == nil)
    #expect(model.userPresenceProtection == .softwareTestOnly)
}

@MainActor
@Test func declinedUserPresenceSendsNoRevocationRequest() async throws {
    let tablet = deviceManagementTestPairedDevice(
        id: "tablet",
        name: "Studio iPad",
        platform: .ipados,
        role: .user
    )
    let provider = DeviceManagementTestDeviceManagementStub(devices: [tablet])
    let presence = DeviceManagementTestTestPresenceAuthorizer(outcome: .decline)
    let model = DeviceManagementModel(
        route: deviceManagementTestDeviceManagementRoute,
        provider: provider,
        userPresenceAuthorizer: presence
    )
    await model.refresh()

    model.requestRevocation(deviceID: tablet.id)
    await model.confirmRevocation()

    #expect(await provider.calls().isEmpty)
    #expect(model.failedRevocation?.device.id == tablet.id)
    #expect(model.revocationErrorMessage?.contains("cancelled") == true)
    #expect(model.devices == [tablet])
}

@MainActor
@Test func unavailableUserPresenceExplainsHowTheOwnerCanRecover() async throws {
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
        userPresenceAuthorizer: DeviceManagementTestTestPresenceAuthorizer(outcome: .unavailable)
    )
    await model.refresh()

    model.requestRevocation(deviceID: tablet.id)
    await model.confirmRevocation()

    #expect(await provider.calls().isEmpty)
    #expect(model.revocationErrorMessage?.contains("device passcode") == true)
}

@MainActor
@Test func ownerSelfRevocationFailureLeavesServerListVisible() async throws {
    let owner = deviceManagementTestPairedDevice(
        id: "owner",
        name: "Alex's iPhone",
        platform: .ios,
        role: .owner
    )
    let observer = deviceManagementTestPairedDevice(
        id: "observer",
        name: "Wall iPad",
        platform: .ipados,
        role: .observer
    )
    let provider = DeviceManagementTestDeviceManagementStub(
        devices: [owner, observer],
        revokeErrors: [
            owner.id: APIError(
                .local(message: "An owner cannot revoke the device making this request."),
                statusCode: 409,
                code: "OWNER_SELF_REVOCATION_FORBIDDEN"
            )
        ]
    )
    let model = DeviceManagementModel(
        route: deviceManagementTestDeviceManagementRoute,
        localDeviceID: owner.id,
        provider: provider,
        userPresenceAuthorizer: DeviceManagementTestTestPresenceAuthorizer()
    )
    await model.refresh()

    model.requestRevocation(deviceID: owner.id)
    await model.confirmRevocation()

    #expect(model.devices == [owner, observer])
    #expect(model.trustedDevices.count == 2)
    #expect(model.failedRevocation?.device.id == owner.id)
    #expect(
        model.revocationErrorMessage?.contains(
            "An owner cannot revoke the device making this request."
        ) == true
    )
}

@MainActor
@Test func lastOwnerFailureIsNotPresentedAsACompletedRevocation() async throws {
    let owner = deviceManagementTestPairedDevice(
        id: "owner",
        name: "Only Owner",
        platform: .macos,
        role: .owner
    )
    let provider = DeviceManagementTestDeviceManagementStub(
        devices: [owner],
        revokeErrors: [
            owner.id: APIError(
                .local(message: "The last owner must remain paired."),
                statusCode: 409,
                code: "LAST_OWNER_REQUIRED"
            )
        ]
    )
    let model = DeviceManagementModel(
        route: deviceManagementTestDeviceManagementRoute,
        provider: provider,
        userPresenceAuthorizer: DeviceManagementTestTestPresenceAuthorizer()
    )
    await model.refresh()

    model.requestRevocation(deviceID: owner.id)
    await model.confirmRevocation()

    #expect(model.devices == [owner])
    #expect(model.trustedDevices == [owner])
    #expect(model.failedRevocation?.device.id == owner.id)
    #expect(model.revocationErrorMessage?.contains("The last owner must remain paired.") == true)
}

@MainActor
@Test func offlineRefreshAndRetryNeverAlterCachedDevices() async throws {
    let devices = [
        deviceManagementTestPairedDevice(
            id: "owner",
            name: "Alex's iPhone",
            platform: .ios,
            role: .owner
        ),
        deviceManagementTestPairedDevice(
            id: "mac",
            name: "Desk Mac",
            platform: .macos,
            role: .developer
        ),
    ]
    let provider = DeviceManagementTestDeviceManagementStub(devices: devices)
    let model = DeviceManagementModel(
        route: deviceManagementTestDeviceManagementRoute,
        provider: provider,
        userPresenceAuthorizer: DeviceManagementTestTestPresenceAuthorizer(),
        now: { deviceManagementTestDeviceManagementDate }
    )
    await model.refresh()
    await provider.setListError(
        APIError(.local(message: "The Spark is offline."), code: "OFFLINE")
    )

    await model.refresh()
    let afterFirstFailure = model.devices
    await model.refresh()

    #expect(afterFirstFailure == devices)
    #expect(model.devices == devices)
    #expect(model.freshness == .cached(refreshedAt: deviceManagementTestDeviceManagementDate))
    #expect(model.readErrorMessage?.contains("Cached devices remain unchanged.") == true)
    #expect(await provider.listCallCount == 3)
}
