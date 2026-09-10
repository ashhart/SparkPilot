import Foundation

/// Declare typed stable-key value copy in the main-bundle catalogue.
extension LocalizedStringResource {
    static func modelProvenance(publisher: String, recipeSource: String) -> Self {
        .init(
            "model.provenance",
            defaultValue: "\(publisher) · recipe by \(recipeSource)",
            comment: "Model publisher followed by the source of its installation recipe."
        )
    }

    static func runningOn(_ location: String) -> Self {
        .init(
            "execution.running.on",
            defaultValue: "Running on \(location)",
            comment: "Accessibility label naming where an AI action runs."
        )
    }

    static func recommendedProfile(_ profile: String) -> Self {
        .init(
            "model.recommended.profile",
            defaultValue: "Recommended: \(profile)",
            comment: "Marks the profile a signed recipe recommends."
        )
    }

    static func readyToJoin(_ network: String) -> Self {
        .init(
            "onboarding.ready.to.join",
            defaultValue: "Ready to join \(network)",
            comment: "Shown only when this device is associated with that Spark setup network."
        )
    }

    static func setupNetworkNotSeen(_ network: String) -> Self {
        .init(
            "onboarding.setup.network.not.seen",
            defaultValue: "\(network) has not been seen on this device yet",
            comment: "A typed setup network name nothing has observed yet."
        )
    }

    static func stepOf(_ step: Int, _ total: Int) -> Self {
        .init(
            "onboarding.step.of",
            defaultValue: "Step \(step) of \(total)",
            comment: "Position within the onboarding sequence."
        )
    }

    static func operationProgress(title: String, stage: String) -> Self {
        .init(
            "activity.operation.progress",
            defaultValue: "\(title), \(stage)",
            comment: "Accessibility label for an operation with no percentage yet."
        )
    }

    // MARK: - Diff

    // Give independently varying counts separate pluralisable keys.

    public static func diffAdditions(_ count: Int) -> Self {
        .init(
            "diff.additions",
            defaultValue: "\(count) additions",
            comment: "How many lines a change adds."
        )
    }

    public static func diffRemovals(_ count: Int) -> Self {
        .init(
            "diff.removals",
            defaultValue: "\(count) removals",
            comment: "How many lines a change removes."
        )
    }

    /// Name how many regions both devices rewrote in a three-way merge (§42.8).
    public static func contestedMergeRegions(_ count: Int) -> Self {
        .init(
            "merge.contested.regions",
            defaultValue: "\(count) regions were rewritten on both devices and stay marked.",
            comment: "How many merge conflicts the owner still has to resolve by hand."
        )
    }

    public static func diffHunks(_ count: Int) -> Self {
        .init(
            "diff.hunks",
            defaultValue: "\(count) hunks",
            comment: "How many separate regions a change touches."
        )
    }

    static func diffSummary(additions: String, removals: String, hunks: String) -> Self {
        .init(
            "diff.summary",
            defaultValue: "Diff, \(additions), \(removals), \(hunks)",
            comment: "Spoken summary of a change whose file name is not known."
        )
    }

    public static func diffSummaryForFile(
        file: String,
        additions: String,
        removals: String,
        hunks: String
    ) -> Self {
        .init(
            "diff.summary.file",
            defaultValue: "\(file), \(additions), \(removals), \(hunks)",
            comment: "Spoken summary of a change to one named file."
        )
    }

    public static func diffAddedLine(_ text: String) -> Self {
        .init(
            "diff.line.added",
            defaultValue: "Added: \(text)",
            comment: "One added line. Colour alone would not distinguish it."
        )
    }

    public static func diffRemovedLine(_ text: String) -> Self {
        .init(
            "diff.line.removed",
            defaultValue: "Removed: \(text)",
            comment: "One removed line."
        )
    }

    static func diffHunkLine(_ text: String) -> Self {
        .init(
            "diff.line.hunk",
            defaultValue: "Hunk \(text)",
            comment: "A unified-diff hunk header naming the line range."
        )
    }

    public static func diffContextLine(_ text: String) -> Self {
        .init(
            "diff.line.context",
            defaultValue: "Unchanged: \(text)",
            comment: "One unchanged line shown for context."
        )
    }

    public static func projectEditorFor(_ path: String) -> Self {
        .init(
            "project.editor.for",
            defaultValue: "Editor for \(path)",
            comment: "Accessibility label for the editor of one named project file."
        )
    }

    public static func projectChangeCounts(additions: Int, deletions: Int) -> Self {
        .init(
            "project.change.counts",
            defaultValue: "+\(additions)  −\(deletions)",
            comment: "Compact additions and deletions counts above one file's diff."
        )
    }

    public static func projectTestEvidence(exitCode: Int, digest: String) -> Self {
        .init(
            "project.test.evidence",
            defaultValue: "Exit \(exitCode) · \(digest)",
            comment: "A test command's exit code and shortened evidence digest."
        )
    }

    public static func projectToolEvidence(sequence: Int, tool: String) -> Self {
        .init(
            "project.tool.evidence",
            defaultValue: "\(sequence). \(tool)",
            comment: "A numbered tool action in an agent change's evidence."
        )
    }

    public static func projectApproveAndMerge(_ project: String) -> Self {
        .init(
            "project.action.approve.merge",
            defaultValue: "Approve and Merge \(project)",
            comment: "Approve the exact reviewed change and merge it into a named project."
        )
    }

    public static func projectRequestChanges(_ project: String) -> Self {
        .init(
            "project.action.request.changes",
            defaultValue: "Request Changes for \(project)",
            comment: "Send a reviewed change back for more work in a named project."
        )
    }

    static func operationProgressPercent(title: String, percent: Int, stage: String) -> Self {
        .init(
            "activity.operation.progress.percent",
            defaultValue: "\(title), \(percent) percent, \(stage)",
            comment: "Progress announced as a percentage and the stage it is in."
        )
    }

    // MARK: - Change approval

    static func changeFilesChanged(_ count: Int) -> Self {
        .init(
            "change.files.changed",
            defaultValue: "\(count) files changed",
            comment: "How many files one agent change touches."
        )
    }

    static func changeCounts(files: String, insertions: Int, deletions: Int) -> Self {
        .init(
            "change.counts",
            defaultValue: "\(files), +\(insertions) −\(deletions)",
            comment: "Files changed plus inserted and deleted line counts."
        )
    }

    static func changeCountsWithTests(files: String, tests: String) -> Self {
        .init(
            "change.counts.tests",
            defaultValue: "\(files) · \(tests)",
            comment: "The change summary with its test outcome appended."
        )
    }

    static func operationReported(_ code: String) -> Self {
        .init(
            "activity.operation.reported",
            defaultValue: "the Spark reported \(code)",
            comment: "Operation failure reason when only the Spark's stable code is available."
        )
    }

    static func operationFailed(_ reason: String) -> Self {
        .init(
            "activity.operation.failed.reason",
            defaultValue: "Failed: \(reason)",
            comment: "Failed operation state followed by its plain-language reason."
        )
    }

    // MARK: - Change status declared here for catalogue extraction

    static var changeCreating: Self {
        .init(
            "change.status.creating",
            defaultValue: "Creating",
            comment: "The agent is preparing a change."
        )
    }

    static var changePlanning: Self {
        .init(
            "change.status.planning",
            defaultValue: "Planning",
            comment: "The agent is deciding what to do."
        )
    }

    static var changeEditing: Self {
        .init(
            "change.status.editing",
            defaultValue: "Editing",
            comment: "The agent is writing the change."
        )
    }

    static var changeReviewReady: Self {
        .init(
            "change.status.review",
            defaultValue: "Review ready",
            comment: "The change is waiting for a person."
        )
    }

    static var changeApproved: Self {
        .init(
            "change.status.approved",
            defaultValue: "Approved",
            comment: "A person approved the change."
        )
    }

    static var changeMerged: Self {
        .init(
            "change.status.merged",
            defaultValue: "Merged",
            comment: "The change was merged."
        )
    }

    static var changeRejected: Self {
        .init(
            "change.status.rejected",
            defaultValue: "Rejected",
            comment: "A person rejected the change."
        )
    }

    static var changeFailed: Self {
        .init(
            "change.status.failed",
            defaultValue: "Failed",
            comment: "The change could not be completed."
        )
    }

    static func changeFilesOnly(_ files: String) -> Self {
        .init(
            "change.files.only",
            defaultValue: "\(files)",
            comment: "The change summary when no line counts are available."
        )
    }

    static var changeTestsPassed: Self {
        .init(
            "change.tests.passed",
            defaultValue: "tests passed",
            comment: "The change's test run succeeded."
        )
    }

    static var changeTestsFailed: Self {
        .init(
            "change.tests.failed",
            defaultValue: "tests failed",
            comment: "The change's test run failed."
        )
    }

    static var changeRejectCopy: Self {
        .init(
            "change.reject.copy",
            defaultValue: "Reject this change and keep the audit trail.",
            comment: "Explains that rejecting a change is recorded."
        )
    }

    static func usedOfTotalGigabytes(used: String, total: String) -> Self {
        .init(
            "measure.used.of.total",
            defaultValue: "\(used) / \(total)",
            comment: "Memory in use against the amount fitted, both already formatted."
        )
    }

    static func percentComplete(_ percent: String) -> Self {
        .init(
            "activity.percent",
            defaultValue: "\(percent) percent",
            comment: "How far an operation has run, spoken alongside its stage."
        )
    }

    /// §52.1's "On Alex's Spark" form for a target reached over the local network or a cable.
    static func onTarget(_ name: String) -> Self {
        .init(
            "execution.target.on",
            defaultValue: "On \(name)",
            comment: "Names the Spark or cluster an action runs on."
        )
    }

    /// §52.1's "Remote connection to your Spark" form.
    static func remoteConnectionTo(_ name: String) -> Self {
        .init(
            "execution.target.remote",
            defaultValue: "Remote connection to \(name)",
            comment: "Names a Spark reached over a remote route rather than the local network."
        )
    }

    static func sparkClusterOfNodes(_ nodes: Int) -> Self {
        .init(
            "execution.target.cluster",
            defaultValue: "Spark cluster · \(nodes) nodes",
            comment: "Names the cluster an action runs on, and how many Sparks are in it."
        )
    }

    static func recommendedProfileSpoken(_ profile: String) -> Self {
        .init(
            "model.recommended.profile.spoken",
            defaultValue: "recommended profile \(profile)",
            comment: "Clause read after a model's name and state in its spoken summary."
        )
    }

    // MARK: - Activity provenance

    // Use plural substitutions for relative-time counts rather than appending language-specific suffixes.

    static func elapsedMinutesAgo(_ minutes: Int) -> Self {
        .init(
            "elapsed.minutes.ago",
            defaultValue: "\(minutes) minutes ago",
            comment: "How long ago an operation reached its current state."
        )
    }

    static func elapsedHoursAgo(_ hours: Int) -> Self {
        .init(
            "elapsed.hours.ago",
            defaultValue: "\(hours) hours ago",
            comment: "How long ago an operation reached its current state."
        )
    }

    static func elapsedDaysAgo(_ days: Int) -> Self {
        .init(
            "elapsed.days.ago",
            defaultValue: "\(days) days ago",
            comment: "How long ago an operation reached its current state."
        )
    }

    static func elapsedWeeksAgo(_ weeks: Int) -> Self {
        .init(
            "elapsed.weeks.ago",
            defaultValue: "\(weeks) weeks ago",
            comment: "How long ago an operation reached its current state."
        )
    }

    static func elapsedMonthsAgo(_ months: Int) -> Self {
        .init(
            "elapsed.months.ago",
            defaultValue: "\(months) months ago",
            comment: "How long ago an operation reached its current state."
        )
    }

    static func elapsedYearsAgo(_ years: Int) -> Self {
        .init(
            "elapsed.years.ago",
            defaultValue: "\(years) years ago",
            comment: "How long ago an operation reached its current state."
        )
    }

    static func durationSeconds(_ seconds: Int) -> Self {
        .init(
            "duration.seconds",
            defaultValue: "\(seconds)s",
            comment: "How long a finished operation took, in seconds."
        )
    }

    static func durationMinutes(_ minutes: Int) -> Self {
        .init(
            "duration.minutes",
            defaultValue: "\(minutes)m",
            comment: "How long a finished operation took, in whole minutes."
        )
    }

    static func durationMinutesSeconds(minutes: Int, seconds: Int) -> Self {
        .init(
            "duration.minutes.seconds",
            defaultValue: "\(minutes)m \(seconds)s",
            comment: "How long a finished operation took, in minutes and seconds."
        )
    }

    static func durationHours(_ hours: Int) -> Self {
        .init(
            "duration.hours",
            defaultValue: "\(hours)h",
            comment: "How long a finished operation took, in whole hours."
        )
    }

    static func durationHoursMinutes(hours: Int, minutes: Int) -> Self {
        .init(
            "duration.hours.minutes",
            defaultValue: "\(hours)h \(minutes)m",
            comment: "How long a finished operation took, in hours and minutes."
        )
    }

    static func activityCompletedWhen(_ when: String) -> Self {
        .init(
            "activity.completed.when",
            defaultValue: "Completed \(when)",
            comment: "When an operation that succeeded finished."
        )
    }

    static func activityFailedWhen(_ when: String) -> Self {
        .init(
            "activity.failed.when",
            defaultValue: "Failed \(when)",
            comment: "When an operation that failed finished."
        )
    }

    static func activityCancelledWhen(_ when: String) -> Self {
        .init(
            "activity.cancelled.when",
            defaultValue: "Cancelled \(when)",
            comment: "When an operation that was cancelled finished."
        )
    }

    static func activityStartedWhen(_ when: String) -> Self {
        .init(
            "activity.started.when",
            defaultValue: "Started \(when)",
            comment: "When an operation still running began."
        )
    }

    static func activityTook(_ duration: String) -> Self {
        .init(
            "activity.took.duration",
            defaultValue: "took \(duration)",
            comment: "Clause following when an operation finished, saying how long it ran."
        )
    }
}

extension LocalizedStringResource {
    static func hostKeyChanged(host: String) -> Self {
        .init(
            "onboarding.hostkey.changed",
            defaultValue:
                "\(host) now presents a different SSH key from the one this device remembers. That is expected after a factory reset. If you did not reset it, do not continue on this network.",
            comment:
                "Shown when a Spark's SSH host key differs from the recorded one; the argument is the hostname."
        )
    }

    static func restartHold(secondsLeft: Int) -> Self {
        .init(
            "onboarding.restart.hold",
            defaultValue:
                "Watching for the Spark to begin restarting. Checks start anyway in \(secondsLeft) seconds.",
            comment:
                "Countdown shown while the app watches for the Spark to drop off the network after first boot."
        )
    }

    static func restartElapsed(clock: String, limitMinutes: Int) -> Self {
        .init(
            "onboarding.restart.elapsed",
            defaultValue: """
                \(clock) elapsed. Checking every few seconds; the wait stops after \
                \(limitMinutes) minutes.
                """,
            comment:
                "How long the app has waited for the Spark to answer after its restart and when it gives up."
        )
    }

    static func rediscoveryElapsed(clock: String, limitMinutes: Int) -> Self {
        .init(
            "onboarding.rediscovery.elapsed",
            defaultValue: """
                \(clock) elapsed. Sparks usually come back within a few minutes; the search stops \
                after \(limitMinutes) minutes.
                """,
            comment: "How long the post-setup search has run and when it gives up."
        )
    }
}
