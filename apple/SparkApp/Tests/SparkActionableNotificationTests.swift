import Foundation
import Testing
@testable import SparkAppComposition

private let actionableTarget = "node:39eab965-a79c-45a5-b20f-9b53bafcf470"
private let actionableProject = "81571818-6ddd-4873-980d-92d6d3a1129f"
private let actionableChange = "1d2a8ac6-6636-4931-9dda-eaaeb8de7c61"
private let actionableEpoch = Date(timeIntervalSince1970: 1_800_000_000)

private func service(_ health: SparkManagedServiceHealth, _ seconds: Double)
    -> SparkManagedServiceObservation
{
    SparkManagedServiceObservation(
        targetID: actionableTarget,
        serviceID: "open-webui",
        state: health,
        observedAt: actionableEpoch.addingTimeInterval(seconds)
    )
}

private func approvals(
    _ seconds: Double,
    review: Bool,
    digest: String = String(repeating: "a", count: 64)
) -> SparkAgentApprovalObservation {
    SparkAgentApprovalObservation(
        targetID: actionableTarget,
        projectID: actionableProject,
        candidates: [
            SparkAgentApprovalCandidate(
                changeID: actionableChange,
                reviewDigest: digest,
                needsReview: review
            )
        ],
        observedAt: actionableEpoch.addingTimeInterval(seconds)
    )
}

@Test func serviceAlertsNeedAnEstablishedHealthyBaselineAndThirtySecondsOfFreshFailure() throws {
    var checkpoint = SparkActionableNotificationCheckpoint()
    #expect(checkpoint.observeService(service(.unhealthy, 0), now: actionableEpoch).isEmpty)
    #expect(
        checkpoint.observeService(
            service(.unhealthy, 40),
            now: actionableEpoch.addingTimeInterval(40)
        ).isEmpty
    )
    #expect(
        checkpoint.observeService(
            service(.healthy, 41),
            now: actionableEpoch.addingTimeInterval(41)
        ).isEmpty
    )
    #expect(
        checkpoint.observeService(
            service(.unhealthy, 42),
            now: actionableEpoch.addingTimeInterval(42)
        ).isEmpty
    )
    #expect(
        checkpoint.observeService(
            service(.unhealthy, 50),
            now: actionableEpoch.addingTimeInterval(50)
        ).isEmpty
    )
    let alerts = checkpoint.observeService(
        service(.unhealthy, 73),
        now: actionableEpoch.addingTimeInterval(73)
    )
    let alert = try #require(alerts.first)
    #expect(alerts.count == 1)
    #expect(alert.serviceID == "open-webui")
    #expect(alert.targetID == actionableTarget)
    #expect(
        checkpoint.observeService(
            service(.unhealthy, 74),
            now: actionableEpoch.addingTimeInterval(74)
        ).isEmpty
    )
    let restored = try JSONDecoder().decode(
        SparkActionableNotificationCheckpoint.self,
        from: JSONEncoder().encode(checkpoint)
    )
    var relaunched = restored
    #expect(
        relaunched.observeService(
            service(.unhealthy, 90),
            now: actionableEpoch.addingTimeInterval(90)
        ).isEmpty
    )
    #expect(
        relaunched.observeService(
            service(.healthy, 91),
            now: actionableEpoch.addingTimeInterval(91)
        ).count == 1
    )
    #expect(
        relaunched.observeService(
            service(.healthy, 92),
            now: actionableEpoch.addingTimeInterval(92)
        ).isEmpty
    )
}

@Test(arguments: [SparkManagedServiceHealth.starting, .stopped, .unknown])
func startupIntentionalStopsAndUnknownOwnershipResetFailureEpisodes(
    _ state: SparkManagedServiceHealth
) {
    var checkpoint = SparkActionableNotificationCheckpoint()
    _ = checkpoint.observeService(service(.healthy, 0), now: actionableEpoch)
    _ = checkpoint.observeService(
        service(.unhealthy, 1),
        now: actionableEpoch.addingTimeInterval(1)
    )
    #expect(
        checkpoint.observeService(service(state, 20), now: actionableEpoch.addingTimeInterval(20))
            .isEmpty
    )
    #expect(
        checkpoint.observeService(
            service(.unhealthy, 50),
            now: actionableEpoch.addingTimeInterval(50)
        ).isEmpty
    )
    #expect(
        checkpoint.observeService(
            service(.unhealthy, 90),
            now: actionableEpoch.addingTimeInterval(90)
        ).isEmpty
    )
}

@Test func staleDuplicateAndOutOfOrderServiceEvidenceCannotCreateAnIncident() {
    var checkpoint = SparkActionableNotificationCheckpoint()
    _ = checkpoint.observeService(service(.healthy, 0), now: actionableEpoch)
    #expect(
        checkpoint.observeService(
            service(.unhealthy, 1),
            now: actionableEpoch.addingTimeInterval(100)
        ).isEmpty
    )
    #expect(checkpoint.observeService(service(.unhealthy, 0), now: actionableEpoch).isEmpty)
    _ = checkpoint.observeService(
        service(.unhealthy, 101),
        now: actionableEpoch.addingTimeInterval(101)
    )
    #expect(
        checkpoint.observeService(
            service(.unhealthy, 99),
            now: actionableEpoch.addingTimeInterval(101)
        ).isEmpty
    )
    #expect(
        checkpoint.observeService(
            service(.healthy, 102),
            now: actionableEpoch.addingTimeInterval(102)
        ).isEmpty
    )
}

@Test func agentApprovalNoticesArePerExactReviewAndNeverReplayLaunchBacklog() throws {
    var checkpoint = SparkActionableNotificationCheckpoint()
    #expect(checkpoint.observeApprovals(approvals(0, review: true), now: actionableEpoch).isEmpty)
    #expect(
        checkpoint.observeApprovals(
            approvals(1, review: true),
            now: actionableEpoch.addingTimeInterval(1)
        ).isEmpty
    )
    _ = checkpoint.observeApprovals(
        approvals(2, review: false),
        now: actionableEpoch.addingTimeInterval(2)
    )
    let notification = try #require(
        checkpoint.observeApprovals(
            approvals(3, review: true),
            now: actionableEpoch.addingTimeInterval(3)
        ).first
    )
    #expect(notification.projectID == actionableProject)
    #expect(notification.changeID == actionableChange)
    #expect(notification.operationID == nil)
    #expect(notification.body == "Open SparkPilot to review the change before approving.")
    #expect(
        checkpoint.observeApprovals(
            approvals(4, review: true),
            now: actionableEpoch.addingTimeInterval(4)
        ).isEmpty
    )
    let bytes = try JSONEncoder().encode(checkpoint)
    var relaunched = try JSONDecoder().decode(
        SparkActionableNotificationCheckpoint.self,
        from: bytes
    )
    #expect(
        relaunched.observeApprovals(
            approvals(5, review: true),
            now: actionableEpoch.addingTimeInterval(5)
        ).isEmpty
    )
    #expect(
        relaunched.observeApprovals(
            approvals(6, review: true, digest: String(repeating: "b", count: 64)),
            now: actionableEpoch.addingTimeInterval(6)
        ).count == 1
    )
    #expect(!String(decoding: bytes, as: UTF8.self).contains("task"))
}

@Test func approvalContentAndMalformedRoutesAreNotStoredAsReviewEvidence() throws {
    var checkpoint = SparkActionableNotificationCheckpoint()
    _ = checkpoint.observeApprovals(approvals(0, review: false), now: actionableEpoch)
    #expect(
        checkpoint.observeApprovals(
            approvals(1, review: true, digest: "private task content"),
            now: actionableEpoch.addingTimeInterval(1)
        ).isEmpty
    )
    #expect(
        !String(decoding: try JSONEncoder().encode(checkpoint), as: UTF8.self).contains(
            "private task content"
        )
    )
    #expect(
        SparkAgentApprovalRoute(
            targetID: actionableTarget,
            projectID: "not-a-project",
            changeID: actionableChange
        ) == nil
    )
    #expect(
        SparkNotificationDestination.resolve(
            category: "SPARK_OPERATION",
            action: "OPEN_ACTIVITY",
            targetID: actionableTarget,
            operationID: nil,
            projectID: actionableProject,
            changeID: actionableChange
        )
            == .projectChange(
                targetID: actionableTarget,
                projectID: actionableProject,
                changeID: actionableChange
            )
    )
    #expect(
        SparkNotificationDestination.resolve(
            category: "SPARK_HEALTH",
            action: "OPEN_SPARK",
            targetID: actionableTarget,
            operationID: nil,
            serviceID: "open-webui"
        )
            == .service(targetID: actionableTarget, serviceID: "open-webui")
    )
}

@Test func oldNotificationCheckpointsRemainReadableAndRevocationDropsActionableBaselines() throws {
    let old = Data(#"{"observations":{},"deliveredIdentifiers":[]}"#.utf8)
    let checkpoint = try JSONDecoder().decode(SparkNotificationCheckpoint.self, from: old)
    #expect(checkpoint.actionable == nil)
    var actionable = SparkActionableNotificationCheckpoint()
    _ = actionable.observeApprovals(approvals(0, review: false), now: actionableEpoch)
    _ = actionable.observeService(service(.healthy, 0), now: actionableEpoch)
    actionable.retainTargets([])
    #expect(actionable.approvals.isEmpty)
    #expect(actionable.services.isEmpty)
}

private actor ActionableDelivery: SparkNotificationDelivering {
    private var failures: Int
    private var values: [SparkLocalNotification] = []
    init(failures: Int = 0) { self.failures = failures }
    func authorization() async -> SparkNotificationAuthorization { .allowed }
    func requestAuthorization() async throws -> Bool { true }
    func registerCategories() async {}
    func deliver(_ notification: SparkLocalNotification) async throws {
        if failures > 0 {
            failures -= 1
            throw NSError(domain: "test.delivery", code: 1)
        }
        values.append(notification)
    }
    func delivered() -> [SparkLocalNotification] { values }
}

@MainActor
@Test func failedLocalDeliveryRetriesItsPersistedIdentifierAfterRelaunch() async throws {
    let suite = "SparkActionableNotificationTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(true, forKey: "enabled")
    let first = SparkNotificationModel(
        delivery: ActionableDelivery(failures: 1),
        defaults: defaults,
        enabledKey: "enabled",
        stateKey: "state"
    )
    await first.prepare()
    let now = Date()
    for (state, date) in [
        (SparkManagedServiceHealth.healthy, now.addingTimeInterval(-40)),
        (.unhealthy, now.addingTimeInterval(-35)), (.unhealthy, now),
    ] {
        await first.observeManagedService(
            SparkManagedServiceObservation(
                targetID: actionableTarget,
                serviceID: "open-webui",
                state: state,
                observedAt: date
            )
        )
    }
    let saved = try JSONDecoder().decode(
        SparkNotificationCheckpoint.self,
        from: #require(defaults.data(forKey: "state"))
    )
    let pending = try #require(saved.actionable?.pending.first)
    let delivery = ActionableDelivery()
    let second = SparkNotificationModel(
        delivery: delivery,
        defaults: defaults,
        enabledKey: "enabled",
        stateKey: "state"
    )
    await second.prepare()
    await second.observeManagedService(
        SparkManagedServiceObservation(
            targetID: actionableTarget,
            serviceID: "open-webui",
            state: .unhealthy,
            observedAt: now.addingTimeInterval(1)
        )
    )
    #expect(await delivery.delivered().map(\.identifier) == [pending.identifier])
    let finished = try JSONDecoder().decode(
        SparkNotificationCheckpoint.self,
        from: #require(defaults.data(forKey: "state"))
    )
    #expect(finished.actionable?.pending.isEmpty == true)
}

@Test func aHandledReviewCancelsUndeliveredApprovalWithoutChangingOtherWatches() throws {
    var checkpoint = SparkActionableNotificationCheckpoint()
    _ = checkpoint.observeApprovals(approvals(0, review: false), now: actionableEpoch)
    let alert = try #require(
        checkpoint.observeApprovals(
            approvals(1, review: true),
            now: actionableEpoch.addingTimeInterval(1)
        ).first
    )
    checkpoint.pending.append(alert)
    _ = checkpoint.observeApprovals(
        approvals(2, review: false),
        now: actionableEpoch.addingTimeInterval(2)
    )
    #expect(checkpoint.pending.isEmpty)
    checkpoint.suspendServiceHealth(targetID: actionableTarget)
    #expect(!checkpoint.approvals.isEmpty)
}
