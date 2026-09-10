import Foundation
import SparkCore
import Testing

@testable import SparkAppComposition

/// Checks notification copy for localisable sentences without private names, prompts, diagnostic codes or routing identifiers.
private let privateThings = [
    "Private Spark Name",
    "PRIVATE_INTERNAL_FAILURE",
    "node:a647b28d-f6ae-4cbc-adf1-f117436a4aaa",
    "meta-llama/Llama-3.1-70B-Instruct",
    "what is my bank balance",
]

private func copyIsSafeAndReadable(_ text: String, what: String) {
    #expect(!text.isEmpty, "\(what) says nothing")
    #expect(text.trimmingCharacters(in: .whitespaces) == text, "\(what) is padded")
    #expect(!text.contains("_"), "\(what) shows an identifier")
    #expect(!text.contains("node:"), "\(what) shows a routing identifier")
    #expect(!text.contains("://"), "\(what) shows a route")
    for secret in privateThings {
        #expect(!text.contains(secret), "\(what) repeats \(secret)")
    }
}

/// Exercise every planner-produced notification through its triggering transition.
private func everyPlannedNotification() -> [SparkLocalNotification] {
    let target = "node:a647b28d-f6ae-4cbc-adf1-f117436a4aaa"
    let operationID = SparkOperationID(rawValue: UUID())
    func observation(
        connection: SparkConnectionState,
        operations: [TargetOperationSnapshot] = [],
        notices: Set<String> = []
    ) -> SparkNotificationObservation {
        SparkNotificationObservation(
            targetID: target,
            connectionState: connection,
            operations: operations,
            noticeCodes: notices
        )
    }
    func operation(_ state: SparkOperationState, kind: String) -> TargetOperationSnapshot {
        TargetOperationSnapshot(
            id: operationID,
            kind: kind,
            state: state,
            progress: 1,
            stage: nil,
            errorCode: "PRIVATE_INTERNAL_FAILURE",
            cancellable: false
        )
    }
    func plan(
        _ old: SparkNotificationObservation,
        _ new: SparkNotificationObservation
    ) -> [SparkLocalNotification] {
        SparkNotificationPlanner.notifications(
            previous: [old.targetID: old],
            current: [new.targetID: new]
        )
    }

    var planned: [SparkLocalNotification] = []
    // Connection, both directions.
    planned += plan(
        observation(connection: .connectedWiFi),
        observation(connection: .offlineCached)
    )
    planned += plan(
        observation(connection: .offlineCached),
        observation(connection: .connectedWiFi)
    )
    // Every terminal operation state, across every kind that changes the title.
    let kinds = [
        "model.install", "model.load", "model.unload", "runtime.update", "some.future.kind",
    ]
    for kind in kinds {
        for state in [SparkOperationState.succeeded, .failed, .cancelled] {
            planned += plan(
                observation(
                    connection: .connectedWiFi,
                    operations: [operation(.running, kind: kind)]
                ),
                observation(connection: .connectedWiFi, operations: [operation(state, kind: kind)])
            )
        }
    }
    // Every notice code that has a presentation.
    let codes = [
        "memory.pressure_warning", "memory.pressure_blocking", "cluster.degraded",
        "inference.failed", "runtime.degraded", "runtime.update_available",
        "runtime.update_required", "target.identity_mismatch",
    ]
    for code in codes {
        planned += plan(
            observation(connection: .connectedWiFi),
            observation(connection: .connectedWiFi, notices: [code])
        )
    }
    // Every inference transition that crosses an actionable boundary.
    func inference(
        _ health: SparkInferenceNotificationHealth,
        _ queue: Int?,
        _ pressure: SparkInferenceNotificationMemoryPressure
    ) -> SparkInferenceNotificationObservation {
        SparkInferenceNotificationObservation(
            targetID: target,
            health: health,
            queueDepth: queue,
            memoryPressure: pressure
        )
    }
    let inferenceTransitions:
        [(SparkInferenceNotificationObservation, SparkInferenceNotificationObservation)] = [
            (inference(.healthy, 0, .normal), inference(.unhealthy, 0, .normal)),
            (inference(.unhealthy, 0, .normal), inference(.healthy, 0, .normal)),
            (inference(.healthy, 0, .normal), inference(.healthy, 8, .normal)),
            (inference(.healthy, 8, .normal), inference(.healthy, 0, .normal)),
            (inference(.healthy, 0, .normal), inference(.healthy, 0, .critical)),
            (inference(.healthy, 0, .normal), inference(.healthy, 0, .emergency)),
        ]
    for (old, new) in inferenceTransitions {
        planned += SparkInferenceNotificationPlanner.notifications(from: old, to: new)
    }
    return planned
}

@Test func everyRegisteredCategoryOffersAnActionThatSaysWhatItDoes() {
    let categories = SparkNotificationCategories.all
    #expect(!categories.isEmpty)
    for category in categories {
        #expect(!category.actions.isEmpty, "\(category.identifier) has no action")
        for action in category.actions {
            copyIsSafeAndReadable(action.title, what: "\(category.identifier) action")
            #expect(
                action.title != action.identifier,
                "\(category.identifier) shows its action identifier as the button"
            )
        }
    }
}

@Test func everyCategoryTheAppDeliversIsOneItRegistered() {
    let registered = Set(SparkNotificationCategories.all.map(\.identifier))
    let delivered = Set(everyPlannedNotification().map(\.category))
    #expect(!delivered.isEmpty)
    let unregistered = delivered.subtracting(registered).sorted().joined(separator: ", ")
    #expect(
        delivered.subtracting(registered).isEmpty,
        "these categories are delivered with no actions registered: \(unregistered)"
    )
}

@Test func everyNotificationSaysSomethingInBothItsTitleAndItsBody() {
    let planned = everyPlannedNotification()
    #expect(planned.count >= 20, "the sweep did not reach the planners")
    for notification in planned {
        copyIsSafeAndReadable(notification.title, what: "title of \(notification.identifier)")
        copyIsSafeAndReadable(notification.body, what: "body of \(notification.identifier)")
        #expect(
            notification.title != notification.body,
            "\(notification.identifier) says the same thing twice"
        )
    }
}

/// Keep target and operation identifiers for notification routing and coalescing separate from visible copy.
@Test func whatRoutesANotificationNeverAppearsInWhatItSays() {
    for notification in everyPlannedNotification() {
        #expect(!notification.title.contains(notification.targetID))
        #expect(!notification.body.contains(notification.targetID))
        if let operationID = notification.operationID {
            #expect(!notification.title.contains(operationID))
            #expect(!notification.body.contains(operationID))
        }
    }
}

/// Map known notice codes to sentences and suppress unmapped codes rather than displaying runtime tokens.
@Test func anUnmappedNoticeCodeIsSilentRatherThanRaw() {
    let target = "node:a647b28d-f6ae-4cbc-adf1-f117436a4aaa"
    func observation(_ notices: Set<String>) -> SparkNotificationObservation {
        SparkNotificationObservation(
            targetID: target,
            connectionState: .connectedWiFi,
            operations: [],
            noticeCodes: notices
        )
    }
    let planned = SparkNotificationPlanner.notifications(
        previous: [target: observation([])],
        current: [target: observation(["something.the_app_has_never_heard_of"])]
    )
    #expect(planned.isEmpty)
}
