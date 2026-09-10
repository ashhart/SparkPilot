import Foundation
import SparkAPI
import SparkWidgetSupport

#if os(iOS) && canImport(ActivityKit)
    import ActivityKit
#endif

@MainActor
enum SparkDownloadActivities {
    static var available: Bool {
        #if os(iOS) && canImport(ActivityKit)
            ActivityAuthorizationInfo().areActivitiesEnabled
        #else
            false
        #endif
    }

    static func show(targetID: String, operation: SparkAPI.Operation) throws {
        #if os(iOS) && canImport(ActivityKit)
            guard available, !content(operation).isTerminal else { return }
            let existing = Activity<SparkDownloadActivityAttributes>.activities
            guard
                !existing.contains(where: {
                    $0.attributes.operationID == operation.id && $0.attributes.targetID == targetID
                })
            else { return }
            // Each activity is explicitly requested by the owner; bound concurrent surfaces.
            guard existing.count < 4 else { throw CocoaError(.featureUnsupported) }
            let state = content(operation)
            _ = try Activity.request(
                attributes: SparkDownloadActivityAttributes(
                    targetID: targetID,
                    operationID: operation.id
                ),
                content: ActivityContent(state: state, staleDate: state.staleAt),
                pushType: nil
            )
        #endif
    }

    static func update(targetID: String, operation: SparkAPI.Operation) async {
        #if os(iOS) && canImport(ActivityKit)
            for activity in Activity<SparkDownloadActivityAttributes>.activities
            where activity.attributes.targetID == targetID
                && activity.attributes.operationID == operation.id
            {
                let state = content(operation)
                let update = ActivityContent(
                    state: state,
                    staleDate: state.isTerminal ? nil : state.staleAt
                )
                if state.isTerminal {
                    await activity.end(
                        update,
                        dismissalPolicy: .after(Date().addingTimeInterval(60))
                    )
                } else {
                    // Operation polling is faster than useful Lock Screen refreshes.
                    guard Date().timeIntervalSince(activity.content.state.observedAt) >= 10 else {
                        continue
                    }
                    await activity.update(update)
                }
            }
        #endif
    }

    private static func content(_ operation: SparkAPI.Operation) -> SparkDownloadActivityState {
        let phase: SparkDownloadActivityState.Phase
        switch operation.state {
        case .succeeded: phase = .succeeded
        case .failed: phase = .failed
        case .cancelled: phase = .cancelled
        case .queued, .requested: phase = .waiting
        default: phase = .downloading
        }
        return SparkDownloadActivityState(
            phase: phase,
            progress: operation.progress,
            observedAt: Date()
        )
    }
}
