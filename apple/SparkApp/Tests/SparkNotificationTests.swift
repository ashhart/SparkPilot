import Foundation
import SparkAPI
import SparkCore
import SparkLibrary
import Testing

@testable import SparkAppComposition

@Test func firstObservationIsABaselineNotAReplayOfOldAlerts() {
    #expect(
        planned(
            from: nil,
            to: notificationObservation(
                connection: .offlineCached,
                operations: [notificationOperation(state: .failed)],
                notices: ["memory.pressure_blocking"]
            )
        ).isEmpty
    )
}

@Test func runningOperationNotifiesExactlyWhenItBecomesTerminal() throws {
    let old = notificationObservation(operations: [notificationOperation(state: .running)])
    let completed = notificationObservation(operations: [notificationOperation(state: .succeeded)])
    let notifications = planned(from: old, to: completed)

    let notification = try #require(notifications.first)
    #expect(notifications.count == 1)
    #expect(notification.title == "A model download finished")
    #expect(notification.category == "SPARK_OPERATION")
    #expect(notification.operationID == notificationOperationID.rawValue.uuidString.lowercased())
    #expect(planned(from: completed, to: completed).isEmpty)
}

@Test func failureNotificationNeverCopiesServerErrorsOrUserContent() throws {
    let notifications = planned(
        from: notificationObservation(operations: [notificationOperation(state: .running)]),
        to: notificationObservation(operations: [notificationOperation(state: .failed)])
    )
    let notification = try #require(notifications.first)

    #expect(notification.title == "A Spark task needs attention")
    #expect(!notification.body.contains("PRIVATE_INTERNAL_FAILURE"))
    #expect(!notification.body.contains("model.install"))
}

@Test func connectionLossAndRecoveryAreSeparateNonRepeatingTransitions() throws {
    let online = notificationObservation(connection: .connectedDirect)
    let offline = notificationObservation(connection: .offlineCached)
    let lost = try #require(planned(from: online, to: offline).first)
    let recovered = try #require(planned(from: offline, to: online).first)

    #expect(lost.title == "A Spark is offline")
    #expect(recovered.title == "A Spark is back online")
    #expect(planned(from: offline, to: offline).isEmpty)
}

@Test func onlyActionableNewHealthNoticesProduceNotifications() {
    let old = notificationObservation(notices: ["evidence.stale"])
    let new = notificationObservation(
        notices: ["evidence.stale", "memory.pressure_warning", "runtime.update_available"]
    )
    let notifications = planned(from: old, to: new)

    #expect(notifications.count == 2)
    #expect(notifications.allSatisfy { $0.category == "SPARK_HEALTH" })
    #expect(notifications.allSatisfy { !$0.body.contains("evidence.stale") })
}

@Test func anUpdateAlreadyRequiredOnFirstObservationIsSurfacedOnce() throws {
    let updateRequired = notificationObservation(notices: ["runtime.update_required"])
    let notification = try #require(planned(from: nil, to: updateRequired).first)

    #expect(notification.title == "A verified Spark update is available")
    #expect(notification.category == "SPARK_HEALTH")
    #expect(planned(from: updateRequired, to: updateRequired).isEmpty)
}

@Test func ordinaryFirstObservationDoesNotCreateNoise() {
    let warning = notificationObservation(notices: ["evidence.stale"])
    #expect(planned(from: nil, to: warning).isEmpty)
}

@Test func notificationActionsOpenTheUsefulProductDestination() {
    let targetID = "node:a647b28d-f6ae-4cbc-adf1-f117436a4aaa"
    #expect(
        SparkNotificationDestination.resolve(
            category: "SPARK_OPERATION",
            action: "com.apple.UNNotificationDefaultActionIdentifier",
            targetID: targetID,
            operationID: notificationOperationID.rawValue.uuidString
        )
            == .operation(
                targetID: targetID,
                operationID: notificationOperationID.rawValue.uuidString.lowercased()
            )
    )
    #expect(
        SparkNotificationDestination.resolve(
            category: "SPARK_HEALTH",
            action: "OPEN_SPARK",
            targetID: targetID,
            operationID: nil
        ) == .home(targetID: targetID)
    )
}

@Test func operationActionShowsOnlyTheExactTargetAndOperation() throws {
    let entry = notificationEntry(operationState: .failed)
    let route = try #require(
        SparkNotificationOperationRoute(
            targetID: entry.id,
            operationID: notificationOperationID.rawValue.uuidString
        )
    )

    let cards = AppleNavigationPlan.activityCards(for: [entry], selected: route)

    #expect(cards.map(\.id) == [notificationOperationID])
    #expect(
        AppleNavigationPlan.activityCards(
            for: [],
            selected: route
        ).isEmpty
    )
}

@MainActor
@Test func relaunchReconcilesMissedCompletionAndCoalescesDuplicates() async throws {
    let suite = "SparkNotificationTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(true, forKey: "enabled")
    let firstDelivery = NotificationDeliverySpy()
    let first = SparkNotificationModel(
        delivery: firstDelivery,
        defaults: defaults,
        enabledKey: "enabled",
        stateKey: "state"
    )
    await first.prepare()
    await first.observe([notificationEntry(operationState: .running)])
    #expect(await firstDelivery.delivered().isEmpty)

    let relaunchedDelivery = NotificationDeliverySpy()
    let relaunched = SparkNotificationModel(
        delivery: relaunchedDelivery,
        defaults: defaults,
        enabledKey: "enabled",
        stateKey: "state"
    )
    await relaunched.prepare()
    let completed = notificationEntry(operationState: .succeeded)
    await relaunched.observe([completed])
    await relaunched.observe([completed])

    let delivered = await relaunchedDelivery.delivered()
    #expect(delivered.count == 1)
    #expect(
        delivered.first?.operationID == notificationOperationID.rawValue.uuidString.lowercased()
    )
}

@MainActor
@Test func existingRequiredRuntimeDeliversOnTheFirstEnabledObservation() async throws {
    let suite = "SparkNotificationTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(true, forKey: "enabled")
    let delivery = NotificationDeliverySpy()
    let model = SparkNotificationModel(
        delivery: delivery,
        defaults: defaults,
        enabledKey: "enabled",
        stateKey: "state"
    )
    await model.prepare()

    await model.observe([
        notificationEntry(operationState: .running, runtimeUpdateState: .required)
    ])
    await model.observe([
        notificationEntry(operationState: .running, runtimeUpdateState: .required)
    ])

    let delivered = await delivery.delivered()
    #expect(delivered.count == 1)
    #expect(delivered.first?.title == "A verified Spark update is available")
}

@MainActor
@Test func staleOfflineAndRevokedTargetsNeverReplayOperationResults() async throws {
    let suite = "SparkNotificationTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(true, forKey: "enabled")
    let delivery = NotificationDeliverySpy()
    let model = SparkNotificationModel(
        delivery: delivery,
        defaults: defaults,
        enabledKey: "enabled",
        stateKey: "state"
    )
    await model.prepare()
    await model.observe([notificationEntry(operationState: .running)])
    await model.observe([
        notificationEntry(
            operationState: .failed,
            connection: .offlineCached,
            operationsAreCurrent: false
        )
    ])
    await model.observe([])

    #expect(await delivery.delivered().allSatisfy { $0.category != "SPARK_OPERATION" })
}

@MainActor
@Test func checkpointAndNotificationCopyExcludePrivateRuntimeContent() async throws {
    let suite = "SparkNotificationTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(true, forKey: "enabled")
    let delivery = NotificationDeliverySpy()
    let model = SparkNotificationModel(
        delivery: delivery,
        defaults: defaults,
        enabledKey: "enabled",
        stateKey: "state"
    )
    await model.prepare()
    await model.observe([notificationEntry(operationState: .failed)])

    let data = try #require(defaults.data(forKey: "state"))
    let persisted = String(decoding: data, as: UTF8.self)
    #expect(!persisted.contains("Private Spark Name"))
    #expect(!persisted.contains("PRIVATE_INTERNAL_FAILURE"))
}

@MainActor
@Test func localOnlyModeSchedulesRefreshWithoutRemoteRegistration() async throws {
    let suite = "SparkNotificationTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(true, forKey: "enabled")
    let scheduler = NotificationBackgroundSchedulerSpy()
    let remote = NotificationRemoteRegistrarSpy()
    let model = SparkNotificationModel(
        delivery: NotificationDeliverySpy(),
        defaults: defaults,
        enabledKey: "enabled",
        stateKey: "state",
        backgroundScheduler: scheduler,
        remoteRegistrar: remote,
        remoteDeliveryEnabled: false
    )

    await model.prepare()

    #expect(scheduler.scheduled == 1)
    #expect(await remote.registrationCount() == 0)
}

@Test func inferenceTransitionsNotifyOnlyWhenTheyCrossAnActionableBoundary() {
    let healthy = SparkInferenceNotificationObservation(
        targetID: "node:stable-id",
        health: .healthy,
        queueDepth: 0,
        memoryPressure: .normal
    )
    let backedUp = SparkInferenceNotificationObservation(
        targetID: "node:stable-id",
        health: .healthy,
        queueDepth: 6,
        memoryPressure: .normal
    )
    let failed = SparkInferenceNotificationObservation(
        targetID: "node:stable-id",
        health: .unhealthy,
        queueDepth: 6,
        memoryPressure: .warning
    )

    #expect(SparkInferenceNotificationPlanner.notifications(from: nil, to: healthy).isEmpty)
    #expect(
        SparkInferenceNotificationPlanner.notifications(from: healthy, to: backedUp)
            .map(\.title) == ["Inference requests are queued"]
    )
    #expect(
        Set(
            SparkInferenceNotificationPlanner.notifications(from: backedUp, to: failed).map(\.title)
        )
            == ["Private AI needs attention", "Spark memory needs attention"]
    )
    #expect(SparkInferenceNotificationPlanner.notifications(from: failed, to: failed).isEmpty)
    #expect(
        Set(SparkInferenceNotificationPlanner.notifications(from: failed, to: healthy).map(\.title))
            == ["Private AI recovered", "Inference queue cleared"]
    )
}

@Test func inferenceNotificationsContainNoReportedIdentityOrRequestContent() {
    let old = SparkInferenceNotificationObservation(
        targetID: "node:secret-host.local",
        health: .healthy,
        queueDepth: 0,
        memoryPressure: .normal
    )
    let new = SparkInferenceNotificationObservation(
        targetID: "node:secret-host.local",
        health: .unhealthy,
        queueDepth: 12,
        memoryPressure: .critical
    )

    for notification in SparkInferenceNotificationPlanner.notifications(from: old, to: new) {
        #expect(!notification.title.contains("secret-host"))
        #expect(!notification.body.contains("secret-host"))
        #expect(!notification.body.contains("prompt"))
        #expect(!notification.body.contains("request body"))
    }
}

extension SparkOperationState {
    var isTerminalForNotificationTest: Bool {
        switch self {
        case .cancelled, .succeeded, .failed: true
        default: false
        }
    }
}

/// §2.5: temperature crossing a sustained threshold is one of the notification categories.
@MainActor
@Test func aSparkRunningHotProducesItsOwnNotification() {
    let target = "entry-hot"
    let cool = SparkNotificationObservation(
        targetID: target,
        connectionState: .connectedWiFi,
        operations: [],
        noticeCodes: []
    )
    let hot = SparkNotificationObservation(
        targetID: target,
        connectionState: .connectedWiFi,
        operations: [],
        noticeCodes: ["node.thermal_warning"]
    )
    let planned = SparkNotificationPlanner.notifications(
        previous: [target: cool],
        current: [target: hot]
    )
    #expect(planned.count == 1)
    #expect(planned.first?.title == "A Spark is running hot")
    #expect(planned.first?.body.contains("temperature") == true)
    #expect(planned.first?.body.contains("°") == false, "no reading belongs in a notification")
}

/// One reading decides Warm and Hot everywhere, instead of each view carrying its own number.
@Test func everySurfaceReadsHeatFromTheSameThresholds() {
    #expect(SparkThermalReading.state(reported: nil, celsius: 20) == .nominal)
    #expect(SparkThermalReading.state(reported: nil, celsius: 78) == .warm)
    #expect(SparkThermalReading.state(reported: nil, celsius: 86) == .hot)
    #expect(SparkThermalReading.state(reported: nil, celsius: 95) == .critical)
    #expect(SparkThermalReading.word(.hot) == FleetHeat.word(86))
    #expect(SparkThermalReading.word(.warm) == FleetHeat.word(78))
}

/// The Spark's own rung wins over any threshold this app carries.
@Test func theSparksReportedRungIsPreferredToTheAppsFallback() {
    #expect(SparkThermalReading.state(reported: "critical", celsius: 20) == .critical)
    #expect(SparkThermalReading.state(reported: "warm", celsius: 95) == .warm)
    #expect(SparkThermalReading.state(reported: "unavailable", celsius: nil) == .unavailable)
    #expect(SparkThermalReading.state(reported: nil, celsius: nil) == .unavailable)
    #expect(SparkThermalReading.state(reported: "something-new", celsius: nil) == .unknown)
    #expect(
        SparkThermalReading.state(reported: nil, celsius: 55, hotCelsius: 50) == .hot,
        "a Spark's own thresholds win once the runtime sends them"
    )
    #expect(SparkThermalReading.needsAttention(.warm) == false)
    #expect(SparkThermalReading.needsAttention(.critical))
}

@Test func openingAppSurfacesCurrentHardwareAlertsWithoutReplayingFinishedTasks() {
    let current = notificationObservation(
        operations: [notificationOperation(state: .failed)],
        notices: ["node.thermal_warning", "memory.pressure_blocking", "cluster.degraded"]
    )
    let alerts = planned(from: nil, to: current)
    #expect(alerts.count == 3)
    #expect(alerts.allSatisfy { $0.category == "SPARK_HEALTH" })
    #expect(planned(from: current, to: current).isEmpty)
    #expect(
        planned(
            from: nil,
            to: notificationObservation(
                connection: .offlineCached,
                notices: current.noticeCodes
            )
        ).isEmpty
    )
}

@MainActor @Test
func currentHardwareAlertsAreVisibleWithoutNotificationPermissionAndClearAfterRecovery() async {
    let defaults = UserDefaults(suiteName: UUID().uuidString)!
    let delivery = NotificationDeliverySpy()
    let model = SparkNotificationModel(delivery: delivery, defaults: defaults)
    let hot = notificationEntry(
        operationState: .failed,
        notices: [OperationalNotice(code: "node.thermal_warning", message: "PRIVATE_HARDWARE_DATA")]
    )
    await model.observe([hot])
    #expect(!model.isEnabled)
    #expect(model.currentAlerts.count == 1)
    #expect(model.currentAlerts.first?.title == "A Spark is running hot")
    #expect(model.currentAlerts.first?.body.contains("PRIVATE_HARDWARE_DATA") == false)
    #expect(await delivery.delivered().isEmpty)
    await model.observe([notificationEntry(operationState: .succeeded)])
    #expect(model.currentAlerts.isEmpty)
    await model.observe([hot])
    #expect(model.currentAlerts.count == 1)
    await model.observe([
        notificationEntry(
            operationState: .failed,
            operationsAreCurrent: false,
            notices: [OperationalNotice(code: "node.thermal_warning", message: "OLD")]
        )
    ])
    #expect(model.currentAlerts.isEmpty)
    await model.observe([])
    #expect(model.currentAlerts.isEmpty)
}

@MainActor @Test func preparedHarnessUpdatesAreDeduplicatedWithoutLeakingProjectNames() {
    let project = GeneratedAPI.Project(
        id: UUID().uuidString,
        name: "PRIVATE_PROJECT",
        state: .ready,
        capabilities: [],
        createdAt: "",
        updatedAt: "",
        harnessUpdates: [
            .init(harness: .ohMyPi, installedVersion: "18.1.11", availableVersion: "18.1.12")
        ]
    )
    let updates = SparkNotificationModel.harnessUpdateNotices(
        targetID: "target",
        projects: [project, project]
    )
    #expect(updates.count == 1)
    #expect(updates.first?.title == "Oh My Pi update available")
    #expect(updates.first?.body.contains("18.1.12") == true)
    #expect(updates.first?.body.contains("PRIVATE_PROJECT") == false)
    var current = project
    current.harnessUpdates = nil
    #expect(
        SparkNotificationModel.harnessUpdateNotices(targetID: "target", projects: [current]).isEmpty
    )
}
