import SparkIntents
import SparkLibrary

@MainActor
enum SparkIntentEntityReconciler {
    static func reconcile(
        _ target: AuthenticatedTarget,
        into library: SparkLibrary,
        refreshShortcutParameters: @MainActor () -> Void = {
            IntentServices.refreshShortcutParameters()
        }
    ) -> ReconciliationOutcome {
        let outcome = library.reconcile(target)
        refreshShortcutParameters()
        return outcome
    }
}
