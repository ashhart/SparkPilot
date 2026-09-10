import Foundation

/// Declare complete typed status sentences so the compiler supplies their format specifiers (§40.4).
extension LocalizedStringResource {
    static func statusReadyLocalNetwork(_ name: String) -> Self {
        .init(
            "status.reachability.local",
            defaultValue: "\(name) is ready over local Wi-Fi.",
            comment: "Spoken status: the Spark answers over the local network."
        )
    }

    static func statusReadyDirectCable(_ name: String) -> Self {
        .init(
            "status.reachability.direct",
            defaultValue: "\(name) is ready over the direct cable.",
            comment: "Spoken status: the Spark answers over the direct Ethernet cable."
        )
    }

    static func statusReadyRemote(_ name: String) -> Self {
        .init(
            "status.reachability.remote",
            defaultValue: "\(name) is ready over remote access.",
            comment: "Spoken status: the Spark answers over its remote route."
        )
    }

    static func statusUnreachable(_ name: String) -> Self {
        .init(
            "status.reachability.unreachable",
            defaultValue: "\(name) is not reachable.",
            comment: "Spoken status: the Spark did not answer."
        )
    }

    static func statusLoadedNoJobs(model: String, memoryPercent: Int) -> Self {
        .init(
            "status.load.model.idle",
            defaultValue: """
                \(model) is loaded, unified memory is \(memoryPercent) percent used, \
                and no jobs are waiting.
                """,
            comment: "Spoken status: a model is loaded and nothing is queued."
        )
    }

    static func statusLoadedWithJobs(
        model: String,
        memoryPercent: Int,
        waitingJobs: Int
    ) -> Self {
        .init(
            "status.load.model.waiting",
            defaultValue: """
                \(model) is loaded, unified memory is \(memoryPercent) percent used, \
                and \(waitingJobs) jobs are waiting.
                """,
            comment: "Spoken status: a model is loaded and work is queued behind it."
        )
    }

    static func statusUnloadedNoJobs(memoryPercent: Int) -> Self {
        .init(
            "status.load.none.idle",
            defaultValue: """
                No model is loaded, unified memory is \(memoryPercent) percent used, \
                and no jobs are waiting.
                """,
            comment: "Spoken status: no model is loaded and nothing is queued."
        )
    }

    static func statusUnloadedWithJobs(memoryPercent: Int, waitingJobs: Int) -> Self {
        .init(
            "status.load.none.waiting",
            defaultValue: """
                No model is loaded, unified memory is \(memoryPercent) percent used, \
                and \(waitingJobs) jobs are waiting.
                """,
            comment: "Spoken status: no model is loaded and work is queued."
        )
    }

    // MARK: - Intent errors (§40.9)

    static var intentNoPairedSpark: Self {
        .init(
            "intent.error.no.paired.spark",
            defaultValue: "No Spark is paired yet. Open the app to set one up.",
            comment: "An intent ran before any Spark was paired."
        )
    }

    static var intentDeviceRevoked: Self {
        .init(
            "intent.error.device.revoked",
            defaultValue: "This device's access was revoked. Re-pair it in the app.",
            comment: "This Apple device's grant was revoked on the Spark."
        )
    }

    static var intentOffline: Self {
        .init(
            "intent.error.offline",
            defaultValue: "Your Spark is not reachable right now.",
            comment: "The Spark did not answer."
        )
    }

    static var intentTargetRequired: Self {
        .init(
            "intent.error.target.required",
            defaultValue: "Choose which Spark or cluster should run this action.",
            comment: "More than one target is paired and the intent named none."
        )
    }

    static var intentTargetUnavailable: Self {
        .init(
            "intent.error.target.unavailable",
            defaultValue: """
                That Spark or cluster is unavailable. Choose another target in the app.
                """,
            comment: "The named target cannot run this action now."
        )
    }

    static var intentPermissionDenied: Self {
        .init(
            "intent.error.permission.denied",
            defaultValue: """
                This device does not have permission to perform that action on the \
                selected Spark.
                """,
            comment: "The Spark refused this device's role for this action."
        )
    }

    static func intentActionRequiresApp(_ reason: String) -> Self {
        .init(
            "intent.error.requires.app",
            defaultValue: "Open SparkPilot to continue. \(reason)",
            comment: "The action needs a decision the app has a screen for."
        )
    }

    static func intentRequestTooLarge(_ limitBytes: Int) -> Self {
        .init(
            "intent.error.too.large",
            defaultValue: """
                This action accepts up to \(limitBytes) bytes. Open SparkPilot for \
                larger work.
                """,
            comment: "The intent's input exceeded the size an intent may carry."
        )
    }

    static func intentModelNotReady(_ model: String) -> Self {
        .init(
            "intent.error.model.loading",
            defaultValue: "\(model) is still loading. Check status in a moment.",
            comment: "The named model is mid-load."
        )
    }

    static func intentModelNotInstalled(_ model: String) -> Self {
        .init(
            "intent.error.model.missing",
            defaultValue: "\(model) isn't installed. Install it from the app first.",
            comment: "The named model is not on the Spark."
        )
    }

    static func intentUnsupportedFileType(_ type: String) -> Self {
        .init(
            "intent.error.file.type",
            defaultValue: "Spark can't read \(type) files. Choose a text file.",
            comment: "The file's type is known and is not readable as text."
        )
    }

    static var intentUnsupportedFileKind: Self {
        .init(
            "intent.error.file.kind",
            defaultValue: "Spark can't read that kind of file. Choose a text file.",
            comment: "The file's type could not be determined."
        )
    }

    static var intentFileHasNoText: Self {
        .init(
            "intent.error.file.empty",
            defaultValue: "That file has no readable text to analyse.",
            comment: "The file was readable and held no text."
        )
    }

    static func intentAnalysisContinues(_ job: String) -> Self {
        .init(
            "intent.analysis.continues",
            defaultValue: """
                Your Spark is still analysing this file. It keeps working as job \
                \(job); use Get Spark Analysis with that job to collect the result.
                """,
            comment: """
                The analysis outlived the intent. Names the job and the shortcut \
                that collects it.
                """
        )
    }

    static func intentAnalysisNotFinished(_ job: String) -> Self {
        .init(
            "intent.analysis.unfinished",
            defaultValue: "Job \(job) is still running on your Spark. Try again in a moment.",
            comment: "The collecting shortcut ran before the job finished."
        )
    }

    static var intentJobUnknown: Self {
        .init(
            "intent.analysis.job.unknown",
            defaultValue: "That isn't a Spark analysis job.",
            comment: "An unnamed job identifier was not one of ours."
        )
    }

    static func intentJobUnknownNamed(_ job: String) -> Self {
        .init(
            "intent.analysis.job.unknown.named",
            defaultValue: "\(job) isn't a Spark analysis job.",
            comment: "The named job identifier was not one of ours."
        )
    }

    static func intentAnalysisFailed(_ reason: String) -> Self {
        .init(
            "intent.analysis.failed",
            defaultValue: "Your Spark could not finish the analysis. \(reason)",
            comment: "The Spark reported why the analysis stopped."
        )
    }

    static var intentAnalysisUnsupported: Self {
        .init(
            "intent.analysis.unsupported",
            defaultValue: """
                This Spark's runtime cannot analyse files yet. Update the Spark \
                runtime first.
                """,
            comment: "The runtime is older than the analysis route."
        )
    }

    // MARK: - Entity subtitles

    static var sparkClusterSubtitle: Self {
        .init(
            "entity.subtitle.cluster",
            defaultValue: "Spark cluster",
            comment: "Shortcuts subtitle for a target that is a cluster of Sparks."
        )
    }

    /// Declare the product name as a protected catalogue key.
    static var dgxSparkSubtitle: Self {
        .init(
            "entity.subtitle.spark",
            defaultValue: "DGX Spark",
            comment: "Shortcuts subtitle for a single Spark. NVIDIA's product name."
        )
    }

    static func loadingModelCheckBack(_ model: String) -> Self {
        .init(
            "intent.loading.model",
            defaultValue: "Loading \(model). Check status in a moment.",
            comment: "Spoken reply after a Shortcuts or Siri load request is accepted."
        )
    }
}
