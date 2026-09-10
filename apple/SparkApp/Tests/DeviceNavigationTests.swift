import Foundation
import SparkAPI
import SparkCore
import SparkLibrary
import SparkSecurity
import Testing
@testable import SparkAppComposition

@MainActor
@Test func deviceAccessIsHiddenWithoutAPairedTrustRecord() throws {
    let runtime = DeviceManagementTestDeviceNavigationRuntime()
    let model = RetailOnboardingModel(
        library: SparkLibrary(store: try SwiftDataLibraryStore()),
        identityResolver: DeviceManagementTestDeviceNavigationIdentityResolver(identitiesByHost: [:]
        ),
        runtime: runtime,
        nodeTrustReader: { _ in nil },
        localDeviceIDProvider: { "local-device" }
    )

    model.recordCompletedSetup(
        route: URL(string: "https://untrusted-spark.local:7443")!,
        authenticated: try deviceManagementTestDeviceNavigationIdentity(
            node: 10,
            name: "Untrusted Spark"
        )
    )

    #expect(model.dashboardModel != nil)
    #expect(model.dashboardTrust == nil)
    #expect(model.deviceManagementModel == nil)
    #expect(!model.canManageDevices)
}

@MainActor
@Test func deviceAccessUsesTheSelectedSparkTargetRouteAndLocalIdentity() async throws {
    let route = URL(string: "https://studio-spark.local:7443")!
    let identity = try deviceManagementTestDeviceNavigationIdentity(node: 11, name: "Studio Spark")
    let trust = deviceManagementTestDeviceNavigationTrust(node: 11, name: "Studio Spark")
    let owner = deviceManagementTestPairedDevice(
        id: "local-device",
        name: "This iPad",
        platform: .ipados,
        role: .owner
    )
    let runtime = DeviceManagementTestDeviceNavigationRuntime(devicesByHost: [route.host!: [owner]])
    let library = SparkLibrary(store: try SwiftDataLibraryStore())
    let outcome = library.reconcile(
        deviceManagementTestDeviceNavigationTarget(
            node: 11,
            host: route.host!,
            name: "Studio Spark"
        )
    )
    let model = RetailOnboardingModel(
        library: library,
        identityResolver: DeviceManagementTestDeviceNavigationIdentityResolver(
            identitiesByHost: [route.host!: identity]
        ),
        runtime: runtime,
        nodeTrustReader: { nodeID in nodeID == trust.nodeID ? trust : nil },
        localDeviceIDProvider: { "local-device" }
    )

    await model.openLibraryEntry(outcome.entry.id)?.value
    let devices = try #require(model.deviceManagementModel)

    #expect(model.canManageDevices)
    #expect(devices.targetID == outcome.entry.id)
    #expect(devices.route == route)
    #expect(devices.localDeviceID == "local-device")
    #expect(model.remoteAccessModel == nil)

    await devices.refresh()
    #expect(devices.devices == [owner])
    #expect(model.remoteAccessModel != nil)
    #expect(await runtime.routes() == [route])
}

@MainActor
@Test func changingTheSelectedSparkCannotLeakAnotherDeviceList() async throws {
    let routeA = URL(string: "https://spark-a.local:7443")!
    let routeB = URL(string: "https://spark-b.local:7443")!
    let identityA = try deviceManagementTestDeviceNavigationIdentity(node: 21, name: "Spark A")
    let identityB = try deviceManagementTestDeviceNavigationIdentity(node: 22, name: "Spark B")
    let trustA = deviceManagementTestDeviceNavigationTrust(node: 21, name: "Spark A")
    let trustB = deviceManagementTestDeviceNavigationTrust(node: 22, name: "Spark B")
    let deviceA = deviceManagementTestPairedDevice(
        id: "a-owner",
        name: "A owner",
        platform: .ios,
        role: .owner
    )
    let deviceB = deviceManagementTestPairedDevice(
        id: "b-owner",
        name: "B owner",
        platform: .macos,
        role: .owner
    )
    let runtime = DeviceManagementTestDeviceNavigationRuntime(
        devicesByHost: [
            routeA.host!: [deviceA],
            routeB.host!: [deviceB],
        ]
    )
    let library = SparkLibrary(store: try SwiftDataLibraryStore())
    let outcomeA = library.reconcile(
        deviceManagementTestDeviceNavigationTarget(node: 21, host: routeA.host!, name: "Spark A")
    )
    let outcomeB = library.reconcile(
        deviceManagementTestDeviceNavigationTarget(node: 22, host: routeB.host!, name: "Spark B")
    )
    let trusts = [trustA.nodeID: trustA, trustB.nodeID: trustB]
    let model = RetailOnboardingModel(
        library: library,
        identityResolver: DeviceManagementTestDeviceNavigationIdentityResolver(
            identitiesByHost: [
                routeA.host!: identityA,
                routeB.host!: identityB,
            ]
        ),
        runtime: runtime,
        nodeTrustReader: { trusts[$0] },
        localDeviceIDProvider: { "local-device" }
    )

    await model.openLibraryEntry(outcomeA.entry.id)?.value
    let devicesA = try #require(model.deviceManagementModel)
    await devicesA.refresh()
    #expect(devicesA.devices == [deviceA])

    model.closeDashboard()
    #expect(model.deviceManagementModel == nil)
    #expect(!model.canManageDevices)

    await model.openLibraryEntry(outcomeB.entry.id)?.value
    let devicesB = try #require(model.deviceManagementModel)
    #expect(devicesA !== devicesB)
    #expect(devicesB.targetID == outcomeB.entry.id)
    #expect(devicesB.route == routeB)
    #expect(!devicesB.devices.contains(where: { $0.id == deviceA.id }))
    #expect(devicesB.devices.allSatisfy { $0.id == deviceB.id })

    await devicesB.refresh()
    #expect(devicesB.devices == [deviceB])
    #expect(devicesB.devices != devicesA.devices)
    #expect(await runtime.routes() == [routeA, routeB])
}

@MainActor
@Test func activeDeviceLastSeenSurvivesRosterDecodingRefreshAndDisplay() async throws {
    // Decode exact roster field names and nanosecond timestamps through the production generated response.
    let wire = "2026-09-04T17:32:45.123456789Z"
    let response = try JSONDecoder().decode(
        GeneratedAPI.ListDevicesResponse200.self,
        from: Data(
            """
            {"items":[{"id":"active-phone","display_name":"Active iPhone","platform":"ios","role":"administrator","capabilities":[],"paired_at":"2026-09-01T09:00:00Z","last_seen_at":"\(wire)","revoked":false}]}
            """.utf8
        )
    )
    let model = DeviceManagementModel(
        route: deviceManagementTestDeviceManagementRoute,
        targetID: "node:active",
        provider: DeviceManagementTestDeviceManagementStub(devices: response.items),
        userPresenceAuthorizer: DeviceManagementTestTestPresenceAuthorizer(),
        cacheStore: DeviceManagementTestInMemoryDeviceListCache()
    )
    await model.refresh()
    let device = try #require(model.displayedDevices.first)
    let seen = try #require(device.lastSeenAt)
    #expect(seen == wire)
    let shown = DeviceGrantPresentation.timestampLabel(seen)
    let expected = try #require(ISO8601DateFormatter().date(from: "2026-09-04T17:32:45Z"))
    #expect(shown == expected.formatted(date: .abbreviated, time: .shortened))
    #expect(shown != String(localized: "Not reported"))
    #expect(shown != wire)
}
