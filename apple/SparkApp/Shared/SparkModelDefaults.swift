import Foundation
import SparkAPI

/// One saved preference per Spark and model, shared by Chat, Home and Models.
@MainActor
enum SparkModelDefaults {
    static func thinkingBudget(
        targetID: String,
        modelID: String,
        defaults: UserDefaults = .standard
    ) -> Int {
        let key = "spark.model-launch.thinking." + targetID + "/" + modelID
        guard defaults.object(forKey: key) != nil else { return 256 }
        return min(8192, max(0, defaults.integer(forKey: key)))
    }

    static func saveThinkingBudget(
        _ budget: Int,
        targetID: String,
        modelID: String,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(
            min(8192, max(0, budget)),
            forKey: "spark.model-launch.thinking." + targetID + "/" + modelID
        )
    }

    static func key(targetID: String, modelID: String) -> String {
        "spark.model-launch.profile." + targetID + "/" + modelID
    }

    /// The signed recipe lists its recommended preset first; the first safe one is the default for a fresh install.
    static func defaultProfile(profiles: [SparkModelProfile]) -> String? {
        profiles.first(where: \.safe)?.id
    }

    /// A remembered preset this recipe no longer lists at all; one it lists as unsafe is shown as such, not as stale.
    static func staleSavedProfile(
        targetID: String,
        modelID: String,
        profiles: [SparkModelProfile],
        defaults: UserDefaults = .standard
    ) -> String? {
        guard let saved = defaults.string(forKey: key(targetID: targetID, modelID: modelID)) else {
            return nil
        }
        return profiles.contains(where: { $0.id == saved }) ? nil : saved
    }

    static func preferred(
        targetID: String,
        modelID: String,
        profiles: [SparkModelProfile],
        defaults: UserDefaults = .standard
    ) -> String? {
        if let saved = defaults.string(forKey: key(targetID: targetID, modelID: modelID)),
            profiles.contains(where: { $0.id == saved && $0.safe })
        {
            return saved
        }
        return defaultProfile(profiles: profiles)
    }

    static func save(
        _ profileID: String,
        targetID: String,
        modelID: String,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(profileID, forKey: key(targetID: targetID, modelID: modelID))
    }
}

extension SparkDashboardModel {
    /// Start with the remembered safe preset; only changed consequences require a review.
    public func startModel(modelID: String, replaceActive: Bool) async {
        guard let item = models.first(where: { $0.id == modelID }),
            let profile = SparkModelDefaults.preferred(
                targetID: targetID,
                modelID: modelID,
                profiles: item.profiles
            ),
            SparkModelDefaults.staleSavedProfile(
                targetID: targetID,
                modelID: modelID,
                profiles: item.profiles
            ) == nil
        else {
            // A remembered preset the recipe dropped is explained in the chooser, never silently swapped.
            await prepareLoad(modelID: modelID, replaceActive: replaceActive)
            return
        }
        await prepareLoad(modelID: modelID, replaceActive: replaceActive, profileID: profile)
        if let confirmation = pendingConfirmation, confirmation.canApply,
            confirmation.preview.action == .load, confirmation.preview.warnings.isEmpty,
            confirmation.preview.consequences.modelToStop == nil,
            !confirmation.preview.consequences.routeWithdrawal
        {
            await applyConfirmation()
        }
    }
}
