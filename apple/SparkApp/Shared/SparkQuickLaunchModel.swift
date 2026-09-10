import Foundation
import Observation
import SparkAPI
import SparkLibrary

@MainActor
@Observable
public final class SparkQuickLaunchModel: Identifiable {
    public let id = UUID()
    public private(set) var choices: [SparkChatTarget] = []
    public private(set) var selectedID: String?
    public private(set) var profiles: [SparkModelProfile] = []
    public var selectedProfileID: String? {
        didSet {
            if let profile = selectedProfile {
                idleSetting =
                    savedIdleSettings[profile.id] ?? SparkModelIdleSetting(profile: profile)
                savedIdleSetting = idleSetting
            }
        }
    }
    public var idleSetting = SparkModelIdleSetting()
    private var savedIdleSetting = SparkModelIdleSetting()
    private var savedIdleSettings: [String: SparkModelIdleSetting] = [:]
    public var idleSettingChanged: Bool { idleSetting != savedIdleSetting }
    public private(set) var isBusy = false
    public private(set) var pendingPlan: SparkModelLaunchPlan?
    public private(set) var errorMessage: String?
    /// Explains a remembered preset the model no longer offers; the default preset stands in for it.
    public private(set) var presetNote: String?
    /// The preset the signed recipe recommends, marked in the picker.
    public var defaultProfileID: String? { SparkModelDefaults.defaultProfile(profiles: profiles) }
    /// Headline for a failure the owner must fix on the Spark before retrying.
    public private(set) var errorTitle: String?
    public private(set) var ready = false
    /// True while the Spark is loading the model; the runtime carries on if this sheet closes.
    public private(set) var isLoading = false
    /// The Spark's stage and percent for the load in progress.
    public private(set) var progress: SparkModelLaunchProgress?
    private let launcher: any SparkModelLaunching
    private let refreshChoices: @MainActor () async -> [SparkChatTarget]
    private var selectionAttempt = UUID()
    private let targetID: String?
    public let launchOnOpen: Bool
    private var hasStarted = false
    public private(set) var readyTarget: SparkChatTarget?

    public init(
        launcher: any SparkModelLaunching,
        targetID: String? = nil,
        launchOnOpen: Bool = false,
        refreshChoices: @escaping @MainActor () async -> [SparkChatTarget]
    ) {
        self.launcher = launcher
        self.refreshChoices = refreshChoices
        self.targetID = targetID
        self.launchOnOpen = launchOnOpen
    }

    public convenience init(
        library: SparkLibrary,
        targetID: String? = nil,
        launchOnOpen: Bool = false
    ) {
        let provider = LocalSparkChatTargetProvider(library: library)
        self.init(
            launcher: SignedSparkModelLauncher(library: library),
            targetID: targetID,
            launchOnOpen: launchOnOpen
        ) {
            await provider.refreshInstalledModels()
            return provider.catalogue().modelChoices
        }
    }

    public var selectedTarget: SparkChatTarget? { choices.first { $0.selectionID == selectedID } }
    public var selectedProfile: SparkModelProfile? { profiles.first { $0.id == selectedProfileID } }

    public func refresh() async {
        // Native menus can reappear with the sheet; keep its selection and review intact.
        guard choices.isEmpty, !isBusy else { return }
        isBusy = true
        let available = await refreshChoices()
        choices = available.filter { targetID == nil || $0.id == targetID }
        isBusy = false
        guard !Task.isCancelled else { return }
        if let first = choices.first {
            await select(first.selectionID)
        } else if targetID != nil {
            errorMessage = String(
                localized:
                    "No installed model is available on this Spark. Open its Models page to download one, or reconnect and try again."
            )
        }
    }

    /// A launch tap starts once; reopening a menu or refreshing never starts a second load.
    public func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        await refresh()
        guard launchOnOpen, !Task.isCancelled else { return }
        await prepare()
    }

    public func select(_ id: String) async {
        guard let target = choices.first(where: { $0.selectionID == id }) else { return }
        cancelReview()
        let attempt = UUID()
        selectionAttempt = attempt
        selectedID = id
        profiles = []
        savedIdleSettings = [:]
        selectedProfileID = nil
        presetNote = nil
        errorMessage = nil
        errorTitle = nil
        ready = false
        readyTarget = nil
        isBusy = true
        defer { if selectionAttempt == attempt { isBusy = false } }
        do {
            let next = try await launcher.profiles(for: target)
            guard selectionAttempt == attempt else { return }
            profiles = next
            // Use a read-only preview to recommend chat's admissible preset, then obtain a fresh review for the owner's choice.
            let recommendation = try await launcher.prepare(target: target, profileID: nil)
            launcher.discard(recommendation)
            guard selectionAttempt == attempt, !Task.isCancelled else { return }
            selectedProfileID =
                recommendation.confirmation?.retryRequest.profileID
                ?? launcher.preferredProfile(for: target, profiles: next)
            if let stale = launcher.staleSavedProfile(for: target, profiles: next) {
                presetNote = String(localized: .savedPresetNoLongerOffered(stale))
            }
        } catch {
            guard selectionAttempt == attempt else { return }
            errorMessage =
                (error as? LocalizedError)?.errorDescription
                ?? String(localized: "The model presets could not be read from the Spark.")
        }
    }

    public func saveIdleSetting() async {
        guard !isBusy, let target = selectedTarget, let profile = selectedProfile else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do { try await persistIdleSetting(target: target, profile: profile) } catch {
            errorMessage =
                (error as? LocalizedError)?.errorDescription
                ?? String(localized: "The Spark did not apply this setting.")
        }
    }

    private func persistIdleSetting(target: SparkChatTarget, profile: SparkModelProfile)
        async throws
    {
        guard idleSettingChanged else { return }
        let setting = idleSetting
        _ = try setting.request(modelID: target.modelID, profile: profile)
        try await launcher.saveIdleSetting(setting, for: target, profile: profile)
        savedIdleSetting = setting
        savedIdleSettings[profile.id] = setting
    }

    public func prepare() async {
        guard !isBusy, let target = selectedTarget, let profile = selectedProfile, profile.safe
        else { return }
        isBusy = true
        errorMessage = nil
        errorTitle = nil
        defer { isBusy = false }
        do {
            try await persistIdleSetting(target: target, profile: profile)
            try Task.checkCancellation()
            let plan = try await launcher.prepare(target: target, profileID: profile.id)
            if plan.alreadyReady {
                try await load(plan)
            } else {
                pendingPlan = plan
                if !plan.requiresApproval { await apply() }
            }
        } catch {
            errorTitle = (error as? SparkModelLaunchError)?.title
            errorMessage =
                (error as? LocalizedError)?.errorDescription
                ?? String(
                    localized: "The launch could not be prepared; check the model in Library."
                )
        }
    }

    public func cancelReview() {
        if let pendingPlan { launcher.discard(pendingPlan) }
        pendingPlan = nil
    }

    public func apply() async {
        guard let plan = pendingPlan else { return }
        pendingPlan = nil
        isBusy = true
        errorTitle = nil
        defer { isBusy = false }
        do {
            try await load(plan)
        } catch {
            errorTitle = (error as? SparkModelLaunchError)?.title
            errorMessage =
                (error as? LocalizedError)?.errorDescription
                ?? String(
                    localized:
                        "The selected model did not become ready; check its status in Library."
                )
        }
    }

    private func load(_ plan: SparkModelLaunchPlan) async throws {
        isLoading = true
        progress = nil
        defer { isLoading = false }
        readyTarget = try await launcher.apply(plan) { [weak self] progress in
            self?.progress = progress
        }
        ready = true
    }

    /// One line for the busy card: the Spark's own stage while loading, otherwise what the sheet is doing.
    public var statusLine: String {
        if isLoading {
            return progress?.line ?? String(localized: "Loading the model on the Spark…")
        }
        return String(localized: "Preparing the model…")
    }
}
