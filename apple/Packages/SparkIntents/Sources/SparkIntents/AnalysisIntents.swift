import AppIntents
import Foundation
import UniformTypeIdentifiers

/// Return completed analysis or a durable job identifier within the foreground intent budget (§40.3).

/// A file in, an analysis out — from Files, the share sheet, or a Shortcut.
public struct AnalyseFileWithSparkIntent: AppIntent {
    public static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    public static let title: LocalizedStringResource = "Analyse File with Spark"
    public static let description = IntentDescription(
        "Analyse a text file with a private model running on your Spark."
    )

    public static let openAppWhenRun = false
    public static let isDiscoverable = true

    public static var parameterSummary: some ParameterSummary {
        Summary("Analyse \(\.$file) on \(\.$target)") {
            \.$instruction
        }
    }

    @Parameter(
        title: "File",
        supportedContentTypes: [.text, .plainText, .utf8PlainText, .json, .yaml, .sourceCode]
    )
    public var file: IntentFile

    @Parameter(
        title: "Instruction",
        default: "Summarise this document accurately and concisely."
    )
    public var instruction: String

    @Parameter(title: "Target", default: nil)
    public var target: SparkTargetEntity?

    public init() {}

    public init(file: IntentFile, instruction: String, target: SparkTargetEntity? = nil) {
        self.file = file
        self.instruction = instruction
        self.target = target
    }

    public func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog
    {
        let input = try SparkFileAnalysisInput.extract(
            data: file.data,
            contentType: file.type,
            suggestedName: file.filename
        )
        let handoff = try await IntentServices.shared.analyseFile(
            input,
            instruction: instruction,
            targetID: target?.id
        )
        return try Self.result(for: handoff)
    }

    /// Use the same pending-analysis interpretation in both intents.
    static func result(
        for handoff: SparkAnalysisHandoff
    ) throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        switch handoff {
        case .running(let jobID):
            throw SparkIntentError.analysisContinuesOnSpark(jobID: jobID)
        case .finished(let text, let truncated):
            let dialog =
                truncated
                ? String(
                    localized:
                        "Here is the analysis. It reached the length limit, so it may be cut short."
                )
                : String(localized: "Here is the analysis.")
            return .result(
                value: text,
                dialog: IntentDialog(
                    full: LocalizedStringResource(stringLiteral: dialog),
                    supporting: ""
                )
            )
        }
    }
}

/// Collect an unfinished or completed durable analysis by its job identifier.
public struct GetSparkAnalysisIntent: AppIntent {
    public static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    public static let title: LocalizedStringResource = "Get Spark Analysis"
    public static let description = IntentDescription(
        "Collect the result of an analysis your Spark is running."
    )

    public static let openAppWhenRun = false
    public static let isDiscoverable = true

    public static var parameterSummary: some ParameterSummary {
        Summary("Get analysis \(\.$jobID) from \(\.$target)")
    }

    @Parameter(title: "Job")
    public var jobID: String

    @Parameter(title: "Target", default: nil)
    public var target: SparkTargetEntity?

    public init() {}

    public init(jobID: String, target: SparkTargetEntity? = nil) {
        self.jobID = jobID
        self.target = target
    }

    public func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog
    {
        // Validate Shortcut-supplied job identifiers as UUIDs before using them in request paths.
        let trimmed = jobID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard UUID(uuidString: trimmed) != nil else {
            throw SparkIntentError.analysisJobUnknown(jobID: trimmed)
        }
        let handoff = try await IntentServices.shared.analysisResult(
            jobID: trimmed,
            targetID: target?.id
        )
        if case .running = handoff {
            throw SparkIntentError.analysisNotFinished(jobID: trimmed)
        }
        return try AnalyseFileWithSparkIntent.result(for: handoff)
    }
}
