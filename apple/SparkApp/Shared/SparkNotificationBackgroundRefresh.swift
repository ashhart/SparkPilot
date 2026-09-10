import Foundation
import SparkLibrary
import SparkProjects
import SparkAPI

#if os(iOS)
    import BackgroundTasks
#endif

@MainActor
public protocol SparkNotificationBackgroundScheduling: AnyObject {
    func schedule()
    func cancel()
}

public enum SparkNotificationBackgroundTask {
    public static let identifier = "com.sparkpilot.operations.refresh"
}

@MainActor
public final class SystemSparkNotificationBackgroundScheduler:
    SparkNotificationBackgroundScheduling
{
    public init() {}

    public func schedule() {
        #if os(iOS)
            let scheduler = BGTaskScheduler.shared
            scheduler.cancel(
                taskRequestWithIdentifier: SparkNotificationBackgroundTask.identifier
            )
            let request = BGAppRefreshTaskRequest(
                identifier: SparkNotificationBackgroundTask.identifier
            )
            request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
            try? scheduler.submit(request)
        #endif
    }

    public func cancel() {
        #if os(iOS)
            BGTaskScheduler.shared.cancel(
                taskRequestWithIdentifier: SparkNotificationBackgroundTask.identifier
            )
        #endif
    }
}

public protocol SparkRemoteNotificationRegistering: Sendable {
    func register() async
}

/// Perform one bounded authenticated background refresh while foreground reconciliation remains the correctness path.
@MainActor
public enum SparkNotificationBackgroundRefresh {
    public static func run(
        library: SparkLibrary,
        notifications: SparkNotificationModel
    ) async {
        await notifications.prepare()
        guard notifications.isEnabled,
            notifications.authorization == .allowed
        else { return }

        let provider = SignedCrossTargetModelLibraryProvider(library: library)
        let model = CrossTargetModelLibraryModel(provider: provider)
        await model.refresh()
        await notifications.observe(library.entries)
        await refreshActionable(library: library, notifications: notifications)
        notifications.scheduleNextBackgroundRefresh()
    }
    /// Refreshes only previously observed services and projects with bounded requests and cancellation checks between signed reads.
    private static func refreshActionable(
        library: SparkLibrary,
        notifications: SparkNotificationModel
    ) async {
        let provider = SignedProjectDataProvider(library: library)
        let connected = Set(
            library.entries.filter { $0.connectionState.isConnected && $0.issue == nil }.map(\.id)
        )
        let deadline = Date().addingTimeInterval(20)
        for targetID in notifications.managedServiceWatches.filter({ connected.contains($0) })
            .prefix(4)
        {
            guard !Task.isCancelled, Date() < deadline else { return }
            if let observation = try? await provider.managedServiceObservation(targetID: targetID),
                !Task.isCancelled
            {
                await notifications.observeManagedService(observation)
            }
        }
        for watch in notifications.approvalWatches.filter({ connected.contains($0.targetID) })
            .prefix(8)
        {
            guard !Task.isCancelled, Date() < deadline else { return }
            guard let projects = try? await provider.projects(targetID: watch.targetID),
                projects.items.contains(where: {
                    $0.id == watch.projectID && $0.capabilities.contains(.review)
                }),
                let changes = try? await provider.changes(
                    targetID: watch.targetID,
                    projectID: watch.projectID
                ), !Task.isCancelled
            else { continue }
            let observation = SparkAgentApprovalObservation(
                targetID: watch.targetID,
                projectID: watch.projectID,
                candidates: changes.filter { $0.projectId == watch.projectID }.map {
                    SparkAgentApprovalCandidate(
                        changeID: $0.id,
                        reviewDigest: $0.reviewDigest,
                        needsReview: $0.status == .review && $0.evidenceComplete
                    )
                },
                observedAt: Date()
            )
            await notifications.observeAgentApprovals(observation)
        }
    }

}
