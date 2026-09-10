import Foundation
import SparkCore
import SparkDesignSystem
import Testing

@Test func operationPresentationCoversStages() {
    #expect(OperationPresentation.stageLabel("downloading") == "Downloading")
    #expect(OperationPresentation.stageLabel("verifying") == "Verifying integrity")
    #expect(OperationPresentation.stageLabel("health_check") == "Health check")
    #expect(
        OperationPresentation.stageLabel("preparing_engine_image")
            == "Preparing vLLM engine"
    )
    #expect(OperationPresentation.stageLabel("starting") == "Starting vLLM service")
    #expect(OperationPresentation.stageLabel(nil) == "Working")
    #expect(OperationPresentation.title(kind: "model.install") == "Downloading model")
    let cancelText = OperationPresentation.cancelCopy(
        OperationCardState(
            id: SparkOperationID(rawValue: UUID()),
            kind: "model.install",
            state: .running,
            stage: "downloading",
            progress: 0.5,
            cancellable: true,
            hasPartialWorkLoss: true
        )
    )
    #expect(cancelText.contains("discard the partial download"))
}

@Test func operationActivityFiltering() {
    let running = OperationCardState(
        id: SparkOperationID(rawValue: UUID()),
        kind: "model.install",
        state: .running,
        stage: "downloading",
        progress: 0.5,
        cancellable: true
    )
    let done = OperationCardState(
        id: SparkOperationID(rawValue: UUID()),
        kind: "model.install",
        state: .succeeded,
        stage: nil,
        progress: nil,
        cancellable: false
    )
    #expect(running.isActive)
    #expect(!done.isActive)
    #expect(running.cancellable)
}

@Test func operationProgressHasASpecificLabelAndAccessibilityTextStacks() {
    let running = OperationCardState(
        id: SparkOperationID(rawValue: UUID()),
        kind: "model.install",
        state: .running,
        stage: "downloading",
        progress: 0.5,
        cancellable: true
    )

    // Expose operation percentage together with its current stage (§51.1).
    #expect(
        String(localized: OperationPresentation.progressAccessibilityLabel(running))
            == "Downloading model, 50 percent, Downloading"
    )
    #expect(OperationPresentation.prefersStackedHeader(usesAccessibilityTextSize: true))
    #expect(!OperationPresentation.prefersStackedHeader(usesAccessibilityTextSize: false))
}

/// Cover every emitted runtime stage and keep unknown free-form stages out of raw UI copy.
@Test func stageLabelsCoverEveryStageTheRuntimeEmits() {
    // Cover runtime load, replacement, unload, update and initial pending stage identifiers.
    let emitted = [
        "pending",
        "draining_previous",
        "stopping_previous",
        "preparing_engine_image",
        "starting",
        "health_check",
        "serving_probe",
        "ready",
        "restoring_previous_engine",
        "draining",
        "stopping",
        "verifying_memory_recovery",
        "unloaded",
        "runtime_update_scheduling",
        "runtime_update_restarting",
    ]
    for stage in emitted {
        let label = OperationPresentation.stageLabel(stage)
        #expect(label != stage, "stage \(stage) is shown to the owner as a raw token")
        #expect(!label.contains("_"), "stage \(stage) leaks an identifier to the owner")
        #expect(!label.isEmpty)
    }
}

/// Resolve unfamiliar stage identifiers through catalogue fallback copy.
@Test func anUnknownStageResolvesToCopyThisBuildHas() {
    #expect(OperationPresentation.stageLabel("some_future_stage") == "Working")
    #expect(OperationPresentation.stageLabel("verifying_memory_recovery_v2") == "Working")
    #expect(OperationPresentation.stageLabel("") == "Working")
    // Missing stage information uses the generic operation description.
    #expect(OperationPresentation.stageLabel(nil) == "Working")
}

/// Distinguish each operation state through words as well as tint (§51.1).
@Test func everyOperationStateCarriesTextAndNotOnlyColour() {
    let states: [SparkOperationState] = [
        .requested, .validating, .queued, .running, .waitingForApproval,
        .cancelling, .cancelled, .succeeded, .failed,
    ]
    var terminal: Set<String> = []
    for state in states {
        let label = OperationPresentation.stateLabel(state)
        #expect(!label.isEmpty, "\(state) has no text of its own")
        #expect(!label.contains("_"), "\(state) shows an identifier")
        #expect(label != state.rawValue, "\(state) shows its raw token")
        if state == .succeeded || state == .failed || state == .cancelled {
            terminal.insert(label)
        }
    }
    #expect(
        terminal.count == 3,
        "two terminal states read the same, so only colour tells them apart"
    )
}

/// Resolve runtime stages and card states into readable accessibility copy.
@Test func theAccessibilitySummaryIsCopyForEveryStageAndState() {
    let stages: [String?] = [
        nil, "pending", "draining_previous", "stopping_previous",
        "preparing_engine_image", "starting", "health_check", "serving_probe",
        "ready", "restoring_previous_engine", "draining", "stopping",
        "verifying_memory_recovery", "unloaded", "runtime_update_scheduling",
        "runtime_update_restarting", "validating", "disk_preflight",
        "downloading", "verifying", "materialising", "some_future_stage",
    ]
    for stage in stages {
        let label =
            stage.map(OperationPresentation.stageLabel)
            ?? OperationPresentation.stageLabel(nil)
        #expect(!label.isEmpty)
        #expect(!label.contains("_"), "stage \(stage ?? "nil") leaks an identifier")
        if let stage { #expect(label != stage) }
    }
}

/// Cancelling says what will be lost, and says it as a sentence either way.
@Test func bothCancellationConfirmationsAreWholeSentences() {
    let losing = OperationCardState(
        id: SparkOperationID(rawValue: UUID()),
        kind: "model.install",
        state: .running,
        stage: "downloading",
        progress: 0.4,
        cancellable: true,
        hasPartialWorkLoss: true
    )
    let keeping = OperationCardState(
        id: SparkOperationID(rawValue: UUID()),
        kind: "model.load",
        state: .running,
        stage: "loading",
        progress: nil,
        cancellable: true,
        hasPartialWorkLoss: false
    )
    let warned = OperationPresentation.cancelCopy(losing)
    let plain = OperationPresentation.cancelCopy(keeping)
    #expect(warned != plain, "the partial-loss warning is not said")
    for copy in [warned, plain] {
        #expect(copy.hasSuffix(".") || copy.hasSuffix("?"), "\(copy) is not a sentence")
        #expect(!copy.contains("_"))
    }
}

/// Every operation kind the app asks about names the work, not the token.
@Test func everyOperationKindResolvesToWordsRatherThanItsToken() {
    let kinds = [
        "model.install", "model.load", "model.unload", "runtime.update",
        "project.agent", "some.future.kind",
    ]
    for kind in kinds {
        let title = OperationPresentation.title(kind: kind)
        #expect(!title.isEmpty)
        #expect(!title.contains("."), "kind \(kind) leaks its identifier")
        #expect(title != kind)
    }
}

/// Show indeterminate activity while work has no measurable progress.
@Test func aRunningOperationWithNoMeasurableProgressShowsIndeterminateActivity() {
    let running = OperationCardState(
        id: SparkOperationID(rawValue: UUID()),
        kind: "model.load",
        state: .running,
        stage: "preparing_engine_image",
        progress: nil,
        cancellable: true,
        hasPartialWorkLoss: false
    )
    #expect(OperationPresentation.showsIndeterminateActivity(running))

    // A measured operation keeps its real bar.
    let measured = OperationCardState(
        id: SparkOperationID(rawValue: UUID()),
        kind: "model.install",
        state: .running,
        stage: "downloading",
        progress: 0.42,
        cancellable: true,
        hasPartialWorkLoss: true
    )
    #expect(!OperationPresentation.showsIndeterminateActivity(measured))

    // A finished operation is not activity, whatever its progress says.
    let finished = OperationCardState(
        id: SparkOperationID(rawValue: UUID()),
        kind: "model.load",
        state: .succeeded,
        stage: "ready",
        progress: nil,
        cancellable: false,
        hasPartialWorkLoss: false
    )
    #expect(!OperationPresentation.showsIndeterminateActivity(finished))
}

// MARK: - PLAN §51.1 accessibility contracts

/// Distinguish every connection state without depending on colour.
@Test func everyStatusHasASymbolAndTextEquivalent() {
    let states: [SparkConnectionState] = [
        .discovering, .foundUnpaired, .connecting, .connectedWiFi, .connectedDirect,
        .connectedRemote, .offlineCached, .identityMismatch, .updateRequired,
    ]
    // Include connection context in accessibility phrases for otherwise identical Ready states.
    var spoken = Set<String>()
    var badges = Set<NodeStatusBadge>()
    for state in states {
        let presentation = NodeStatusPresentation.resolve(state)
        #expect(!presentation.title.isEmpty, "\(state) has no title")
        #expect(!presentation.secondary.isEmpty, "\(state) has no explanation")
        spoken.insert("\(presentation.title), \(presentation.secondary)")
        badges.insert(NodeStatusPresentation.badge(for: state))
    }
    #expect(
        spoken.count == states.count,
        "two connection states read identically, so text alone cannot tell them apart"
    )
    #expect(badges.count > 1, "one badge for every state carries no information")
}

/// §51.1: a diff announces its file, its hunks and what changed.
@Test func aDiffAnnouncesItsFileHunksAndChanges() {
    let lines = DiffParser.parse(
        unifiedDiff: """
            @@ -1,3 +1,4 @@
             context
            -removed line
            +added line
            +second added line
            """
    )
    let counts = DiffAccessibility.counts(lines)
    #expect(counts.additions == 2)
    #expect(counts.removals == 1)
    #expect(counts.hunks == 1)

    let summary = String(localized: DiffAccessibility.summary(file: "Engine.swift", lines: lines))
    #expect(summary.contains("Engine.swift"), "\(summary)")
    // Test source-language defaults here and compiled singular forms in built-product catalogue checks.
    #expect(summary.contains("2 addition"), "\(summary)")
    #expect(summary.contains("1 removal"), "\(summary)")
    #expect(summary.contains("1 hunk"), "\(summary)")

    // A line's fate is spoken, not left to its colour.
    let added = lines.first { $0.prefix == .addition }!
    let removed = lines.first { $0.prefix == .deletion }!
    #expect(String(localized: DiffAccessibility.lineLabel(added)).hasPrefix("Added: "))
    #expect(String(localized: DiffAccessibility.lineLabel(removed)).hasPrefix("Removed: "))
    #expect(
        String(localized: DiffAccessibility.lineLabel(added))
            != String(localized: DiffAccessibility.lineLabel(removed)),
        "an addition and a removal read the same"
    )

    // The displayed symbol must also distinguish the diff state without colour.
    #expect(DiffAccessibility.glyph(.addition) != DiffAccessibility.glyph(.deletion))
}

/// Expose both stage and percentage when available, with useful indeterminate guidance (§51.1).
@Test func progressExposesPercentageAndStage() {
    let measured = OperationCardState(
        id: SparkOperationID(rawValue: UUID()),
        kind: "model.install",
        state: .running,
        stage: "verifying",
        progress: 0.42,
        cancellable: true
    )
    let spoken = String(localized: OperationPresentation.progressAccessibilityLabel(measured))
    #expect(spoken.contains("42 percent"), "\(spoken)")
    #expect(spoken.contains("Verifying integrity"), "\(spoken)")

    let unmeasured = OperationCardState(
        id: SparkOperationID(rawValue: UUID()),
        kind: "model.install",
        state: .running,
        stage: "preparing_engine_image",
        progress: nil,
        cancellable: true
    )
    let stageOnly = String(localized: OperationPresentation.progressAccessibilityLabel(unmeasured))
    #expect(stageOnly.contains("Preparing vLLM engine"), "\(stageOnly)")
    #expect(!stageOnly.contains("percent"), "a percentage was invented for unmeasured work")
}

private func activityTestOperationCard(
    state: SparkOperationState,
    createdAt: Date? = nil,
    startedAt: Date? = nil,
    completedAt: Date? = nil
) -> OperationCardState {
    OperationCardState(
        id: SparkOperationID(rawValue: UUID()),
        kind: "model.install",
        state: state,
        stage: "downloading",
        progress: 0.5,
        cancellable: true,
        createdAt: createdAt,
        startedAt: startedAt,
        completedAt: completedAt
    )
}

/// §62.3 requires the operation screen to say what happens if the app closes.
@Test func anActiveJobSaysItContinuesWhenTheAppCloses() {
    let running = activityTestOperationCard(state: .running)
    #expect(OperationPresentation.closingCopy(running)?.contains("continues on the Spark") == true)
    #expect(OperationPresentation.closingCopy(activityTestOperationCard(state: .succeeded)) == nil)
}

/// §41.8's timeline orders by the most recent instant, not by which Spark the job belongs to.
@Test func aCardKnowsItsMostRecentInstant() {
    let created = Date(timeIntervalSince1970: 100)
    let started = Date(timeIntervalSince1970: 200)
    let completed = Date(timeIntervalSince1970: 300)
    #expect(
        activityTestOperationCard(state: .running, createdAt: created, startedAt: started)
            .mostRecentInstant == started
    )
    #expect(
        activityTestOperationCard(
            state: .succeeded,
            createdAt: created,
            startedAt: started,
            completedAt: completed
        ).mostRecentInstant == completed
    )
    #expect(activityTestOperationCard(state: .queued).mostRecentInstant == nil)
}
