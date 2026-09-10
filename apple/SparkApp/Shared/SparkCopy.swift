import Foundation

/// Stable catalogue keys with typed interpolation arguments, resolved from the application bundle.
extension LocalizedStringResource {
    static func chatWebAndPersonalContext(summary: String) -> Self {
        .init(
            "chat.web.personal.warning",
            defaultValue:
                "This conversation has web access and your personal information in it (\(summary)). Search queries may include details from this conversation, and pages can contain misleading instructions. Turn off web access before discussing anything you want to keep on your Spark.",
            comment:
                "Shown when a conversation has both shared personal context and permission to read the web."
        )
    }

    static func chatDraft(_ text: String) -> Self {
        .init(
            "chat.draft.preview",
            defaultValue: "Draft: \(text)",
            comment: "An unsent draft shown in the chat list."
        )
    }

    static func chatThoughtFor(_ duration: String) -> Self {
        .init(
            "chat.thought.duration",
            defaultValue: "Thought for \(duration)",
            comment: "Completed model reasoning, with a locale-formatted elapsed duration."
        )
    }

    static func chatContextUse(used: String, limit: String, percent: String) -> Self {
        .init(
            "chat.context.use",
            defaultValue: "\(used) of \(limit) · \(percent)",
            comment: "Context window use under the chat model: tokens used, the window, the share."
        )
    }

    static func chatContextUsed(_ used: String) -> Self {
        .init(
            "chat.context.used",
            defaultValue: "\(used) used",
            comment: "Context use when the Spark did not report the model's window size."
        )
    }

    static func chatResponseTokens(_ tokens: String) -> Self {
        .init(
            "chat.response.tokens",
            defaultValue: "\(tokens) tokens",
            comment: "Tokens in one response, shown in its footer."
        )
    }

    static func chatResponseRate(_ rate: String) -> Self {
        .init(
            "chat.response.rate",
            defaultValue: "\(rate) tokens/s",
            comment: "Generation speed for one response, shown in its footer."
        )
    }

    // MARK: - Charts drawn from a model's chart block or from a table in its answer

    static func chartTitled(kind: String, title: String) -> Self {
        .init(
            "chart.spoken.title",
            defaultValue: "\(kind), \(title).",
            comment: "Opens a chart's spoken summary with its kind and its own title."
        )
    }

    static func chartSeriesRange(
        name: String,
        latest: String,
        lowest: String,
        highest: String
    ) -> Self {
        .init(
            "chart.spoken.series",
            defaultValue: "\(name): latest \(latest), lowest \(lowest), highest \(highest).",
            comment: "What one series of a chart shows, for a reader who cannot see its shape."
        )
    }

    static func chartReadingWithUnit(value: String, unit: String) -> Self {
        .init(
            "chart.reading.unit",
            defaultValue: "\(value) \(unit)",
            comment: "A chart value and the unit the chart declared for it."
        )
    }

    static func chartOfSeriesBy(series: String, label: String) -> Self {
        .init(
            "chart.table.title",
            defaultValue: "\(series) by \(label)",
            comment: "Title for a chart built from a table: its numeric columns against its first."
        )
    }

    static func chartAxisWithUnit(label: String, unit: String) -> Self {
        .init(
            "chart.axis.unit",
            defaultValue: "\(label) (\(unit))",
            comment: "A chart axis name followed by the unit its readings are in."
        )
    }

    static func chartShownAsText(_ reason: String) -> Self {
        .init(
            "chart.fallback.note",
            defaultValue: "Shown as text. \(reason)",
            comment: "One line under a chart block the app could not draw, and why."
        )
    }

    // MARK: - Composition

    static func pair(_ first: String, _ second: String) -> Self {
        .init(
            "accessibility.pair",
            defaultValue: "\(first), \(second)",
            comment: "Two already-localised parts read as one phrase."
        )
    }

    static func triple(_ first: String, _ second: String, _ third: String) -> Self {
        .init(
            "accessibility.triple",
            defaultValue: "\(first), \(second), \(third)",
            comment: "Three already-localised parts read as one phrase."
        )
    }

    static func labelledValue(title: String, value: String) -> Self {
        .init(
            "accessibility.labelled.value",
            defaultValue: "\(title): \(value)",
            comment: "One reading and its label, read as one phrase."
        )
    }

    static func sentencePair(_ first: String, _ second: String) -> Self {
        .init(
            "accessibility.sentence.pair",
            defaultValue: "\(first) \(second)",
            comment: "Two already-localised sentences shown one after the other."
        )
    }

    static func joined(_ first: String, _ second: String) -> Self {
        .init(
            "display.joined",
            defaultValue: "\(first) · \(second)",
            comment: "Two short display values shown side by side."
        )
    }

    // MARK: - Confirmations name both the action and its resource

    static func openResource(_ resource: String) -> Self {
        .init("action.open", defaultValue: "Open \(resource)", comment: "Open a named thing.")
    }

    static func aboutResource(_ resource: String) -> Self {
        .init("action.about", defaultValue: "About \(resource)", comment: "Explain a named thing.")
    }

    static func downloadResource(_ resource: String) -> Self {
        .init(
            "action.download",
            defaultValue: "Download \(resource)",
            comment: "Download a named model."
        )
    }

    static func stopResource(_ resource: String) -> Self {
        .init("action.stop", defaultValue: "Stop \(resource)", comment: "Stop a named model.")
    }

    static func removeResource(_ resource: String) -> Self {
        .init(
            "action.remove",
            defaultValue: "Remove \(resource)",
            comment: "Remove a named model or credential."
        )
    }

    static func revokeResource(_ resource: String) -> Self {
        .init(
            "action.revoke",
            defaultValue: "Revoke \(resource)",
            comment: "Revoke a named device's grant."
        )
    }

    static func checkResource(_ resource: String) -> Self {
        .init(
            "action.check",
            defaultValue: "Check \(resource)",
            comment: "Read-only preflight against a named Spark."
        )
    }

    static func showDetailsFor(_ resource: String) -> Self {
        .init(
            "action.show.details",
            defaultValue: "Show details for \(resource)",
            comment: "Open one Spark's detail view."
        )
    }

    static func selectForClusterReview(_ resource: String) -> Self {
        .init(
            "action.select.for.cluster.review",
            defaultValue: "Select \(resource) for cluster review",
            comment: "Choose a member while reviewing an external cluster."
        )
    }

    static func clusterTrustUnavailable(_ spark: String) -> Self {
        .init(
            "cluster.trust.unavailable",
            defaultValue:
                "The saved trust record for \(spark) is unavailable. Pair it again before clustering.",
            comment: "A selected Spark no longer has its saved trust record."
        )
    }

    static func clusterDescriptorMismatch(_ spark: String) -> Self {
        .init(
            "cluster.descriptor.mismatch",
            defaultValue:
                "\(spark) returned cluster identity details that do not match its paired record.",
            comment: "A selected Spark returned identity facts that conflict with its trust record."
        )
    }

    static func clusterPrepareFailed(_ spark: String) -> Self {
        .init(
            "cluster.prepare.failed",
            defaultValue: "\(spark) could not prepare its cluster link. Nothing was committed.",
            comment: "One Spark failed before the cluster transaction committed."
        )
    }

    static func clusterLinkProofFailed(_ spark: String) -> Self {
        .init(
            "cluster.link.proof.failed",
            defaultValue:
                "\(spark) could not prove its assigned peer over the CX-7 link. SparkPilot rolled the transaction back.",
            comment: "One Spark could not prove the expected physical cluster peer."
        )
    }

    static func clusterCommitFailed(_ spark: String) -> Self {
        .init(
            "cluster.commit.failed",
            defaultValue:
                "\(spark) could not commit the cluster. SparkPilot rolled the transaction back.",
            comment: "One Spark failed while durably committing cluster membership."
        )
    }

    static func clusterFinalizeFailed(_ spark: String) -> Self {
        .init(
            "cluster.finalize.failed",
            defaultValue:
                "\(spark) could not confirm both cluster commits. SparkPilot rolled the transaction back.",
            comment: "One Spark failed while confirming every member's commit receipt."
        )
    }

    static func clusterRollbackIncomplete(_ sparks: String) -> Self {
        .init(
            "cluster.rollback.incomplete",
            defaultValue:
                "Cluster setup stopped, but \(sparks) did not confirm rollback. Do not start distributed inference yet.",
            comment: "Names the Sparks that did not confirm rollback after cluster setup failed."
        )
    }

    static func reviewExactAdoption(_ resource: String) -> Self {
        .init(
            "action.review.adoption",
            defaultValue: "Review exact adoption of \(resource)",
            comment: "Open the signed-recipe review for an external workload."
        )
    }

    // MARK: - State and evidence

    static func refreshFailed(_ reason: String) -> Self {
        .init(
            "state.refresh.failed",
            defaultValue: "Refresh failed. \(reason)",
            comment: "A refresh failed and the runtime gave a reason."
        )
    }

    static func deviceIdentityUnavailable(_ detail: String) -> Self {
        .init(
            "composition.device.identity.unavailable",
            defaultValue: """
                SparkPilot could not access its device identity in Keychain. \
                Unlock this device and reopen the app; do not reset its identity \
                or remove existing pairings. (\(detail))
                """,
            comment:
                "Startup failed while loading the persistent signing identity, not the release trust root."
        )
    }

    static func deviceIdentityTemporarilyUnavailable(_ detail: String) -> Self {
        .init(
            "composition.device.identity.temporarily.unavailable",
            defaultValue: """
                SparkPilot could not read its device identity from the Keychain this \
                time. This usually clears on a retry; if it keeps happening, the app's \
                signing or entitlements are incomplete. Nothing was reset. (\(detail))
                """,
            comment:
                "Startup hit errSecMissingEntitlement, which is usually transient; retry is the remedy."
        )
    }

    static func chooseProfileBeforeLoading(_ model: String) -> Self {
        .init(
            "intent.choose.profile",
            defaultValue: "Choose a compatible model profile before loading \(model).",
            comment: "An App Intent needs a profile chosen in the app first."
        )
    }

    // MARK: - Telemetry readings keep units and connective words in complete localisable phrases

    static func loadAverage(_ value: String) -> Self {
        .init(
            "telemetry.load.average",
            defaultValue: "1 minute load average \(value)",
            comment: "Processor load over the last minute."
        )
    }

    static func hermesContextTooSmall(_ context: String) -> Self {
        .init(
            "developer.hermes.context.small",
            defaultValue:
                "Hermes Agent needs at least a 64K context window; this model has \(context).",
            comment:
                "Hermes cannot use the selected model; context is the model's formatted token limit."
        )
    }

    static func launchDeveloperTool(_ tool: String) -> Self {
        .init(
            "developer.launch.tool",
            defaultValue: "Launch \(tool)",
            comment: "Accessible name for the button that launches a named developer tool."
        )
    }

    static func openedWithDeveloperModel(_ model: String) -> Self {
        .init(
            "developer.opened.model",
            defaultValue: "Opened with \(model)",
            comment: "Confirms that a developer tool opened using the named model."
        )
    }

    // MARK: - Runtime update diagnostics

    static func stepOfTotal(_ step: Int, _ total: Int) -> Self {
        .init(
            "settings.update.step",
            defaultValue: "Step \(step) of \(total)",
            comment: "Current numbered step in a runtime update."
        )
    }
}

extension LocalizedStringResource {
    static func blankPDFPage(_ page: Int) -> Self {
        .init(
            "chat.attachment.pdf.blank.page",
            defaultValue: "[Page \(page) has no readable text]",
            comment:
                "Stands in for a PDF page with no extractable text so page numbering stays intact."
        )
    }

    static func unreadableShares(_ count: Int) -> Self {
        .init(
            "chat.shares.unreadable.count",
            defaultValue:
                "\(count) shared items could not be read. Removing them keeps every readable share.",
            comment:
                "Shared items that could not be opened; removing them leaves readable ones alone."
        )
    }

    static func servingBusy(active: Int, queued: Int) -> Self {
        .init(
            "inference.verdict.busy",
            defaultValue:
                "Busy: \(active) answering and \(queued) waiting. New requests queue behind them.",
            comment: "The engine has a queue; new requests wait."
        )
    }

    static func servingAnswering(active: Int, tokensPerSecond: String) -> Self {
        .init(
            "inference.verdict.answering.rate",
            defaultValue: "Answering \(active) requests at \(tokensPerSecond) tokens per second.",
            comment: "The engine is answering with a measured generation rate."
        )
    }

    static func servingAnswering(active: Int) -> Self {
        .init(
            "inference.verdict.answering",
            defaultValue: "Answering \(active) requests.",
            comment: "The engine is answering; no rate measured yet."
        )
    }
}

extension LocalizedStringResource {
    static func joinCodesLocked(minutes: Int) -> Self {
        .init(
            "pairing.join.code.locked",
            defaultValue: """
                Too many join codes were tried on this Spark, so it is not accepting any for about \
                \(minutes) minutes. Your code stays valid until it expires; try again after the wait.
                """,
            comment: "The Spark paused join-code attempts after repeated failures."
        )
    }
}

extension LocalizedStringResource {
    static func unreclaimedMemory(model: String, short: String, free: String) -> Self {
        .init(
            "dashboard.unload.memory.unreclaimed",
            defaultValue: """
                \(model) stopped, but \(short) has not returned: \(free) is free now. The next \
                model may not fit until it does. Check again once the Spark settles; if it stays \
                short, restart the Spark.
                """,
            comment:
                "An engine stopped without giving its memory back; the owner can recheck or restart."
        )
    }
}

extension LocalizedStringResource {
    static func operationElapsed(clock: String) -> Self {
        .init(
            "operation.elapsed",
            defaultValue: "\(clock) elapsed",
            comment:
                "How long a Spark operation with no percentage has been running; the argument is a m:ss clock."
        )
    }

    static func percentComplete(_ percent: String) -> Self {
        .init(
            "progress.percent.complete",
            defaultValue: "\(percent) complete",
            comment: "Progress with no stage name from the Spark."
        )
    }

    static func loadingModel(_ model: String) -> Self {
        .init(
            "dashboard.model.loading",
            defaultValue: "Loading \(model)…",
            comment: "Header status while a model loads; model is its display name."
        )
    }

    static func loadingModelStage(_ model: String, stage: String) -> Self {
        .init(
            "dashboard.model.loading.stage",
            defaultValue: "Loading \(model) · \(stage)",
            comment: "Header status while a model loads, with the Spark's stage."
        )
    }

    static func loadingModelStagePercent(_ model: String, stage: String, percent: Int) -> Self {
        .init(
            "dashboard.model.loading.stage.percent",
            defaultValue: "Loading \(model) · \(stage) · \(percent)%",
            comment: "Header status while a model loads, with stage and percent."
        )
    }

    static func macMenuBarReachable(reachable: String, total: String) -> Self {
        .init(
            "mac.menubar.reachable",
            defaultValue: "\(reachable) of \(total) reachable",
            comment: "Menu-bar summary of how many paired Sparks answer right now."
        )
    }

    static func restartResourceAt(_ resource: String, _ context: String) -> Self {
        .init(
            "a11y.restart.resource.context",
            defaultValue: "Restart \(resource) at \(context)",
            comment: "Spoken label for PLAN 41.9's restart button; 51.1 wants the resource named."
        )
    }

    static func diagnosticsForResource(_ resource: String) -> Self {
        .init(
            "a11y.diagnostics.resource",
            defaultValue: "Show diagnostics for \(resource)",
            comment: "Spoken label for PLAN 41.9's diagnostics button."
        )
    }

    static func leaveResourceStopped(_ resource: String) -> Self {
        .init(
            "a11y.leave.stopped",
            defaultValue: "Leave \(resource) stopped",
            comment: "Spoken label for PLAN 41.9's Not now button."
        )
    }

    static func memoryStopWithSmallerContext(selected: String, smaller: String) -> Self {
        .init(
            "model.memory.stop.smaller",
            defaultValue:
                "The selected \(selected) context used more memory than expected. You can restart at \(smaller) or inspect diagnostics.",
            comment:
                "PLAN 41.9's memory-stop wording, naming the context that stopped and the one that fits."
        )
    }

    static func memoryStopNoSmallerContext(_ selected: String) -> Self {
        .init(
            "model.memory.stop.only",
            defaultValue:
                "The selected \(selected) context used more memory than expected. There is no smaller context installed for this model; inspect diagnostics to see what happened.",
            comment: "PLAN 41.9's memory-stop wording when no smaller profile exists to offer."
        )
    }

    static func restartAtContext(_ context: String) -> Self {
        .init(
            "model.memory.stop.restart",
            defaultValue: "Restart at \(context)",
            comment: "PLAN 41.9's first button, naming the smaller context it would start."
        )
    }

    static func contextShorthand(_ thousands: String) -> Self {
        .init(
            "model.context.shorthand",
            defaultValue: "\(thousands)K",
            comment: "A context window in the owner's shorthand: 32768 tokens reads as 32K."
        )
    }

    static func macMenuBarSpark(name: String, state: String) -> Self {
        .init(
            "mac.menubar.spark",
            defaultValue: "\(name) — \(state)",
            comment: "One Spark's line in the menu bar: its name and its connection state."
        )
    }

    static func macMenuBarSparkDetail(name: String, state: String, detail: String) -> Self {
        .init(
            "mac.menubar.spark.detail",
            defaultValue: "\(name) — \(state) · \(detail)",
            comment: "One Spark's menu-bar line with the model it is running or its last contact."
        )
    }

    static func macProjectWindowTitle(project: String, spark: String) -> Self {
        .init(
            "mac.project.window.title",
            defaultValue: "\(project) on \(spark)",
            comment: "Title of a Mac window opened on one project of one Spark."
        )
    }
}
