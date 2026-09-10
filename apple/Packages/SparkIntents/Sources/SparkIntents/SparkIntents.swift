import AppIntents
import Foundation

/// Bound short intent requests and return real durable-operation IDs for model mutations (§40.2).

/// "Ask Spark" — question in, answer out (§40.3).
public struct AskSparkIntent: AppIntent {
    public static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    public static let title: LocalizedStringResource = "Ask Spark"
    public static let description = IntentDescription(
        "Ask a private model running on your Spark."
    )

    // No intent opens SparkPilot, so Siri answers hands-free, and every one stays discoverable because each is a registered App Shortcut.
    public static let openAppWhenRun = false
    public static let isDiscoverable = true

    public static var parameterSummary: some ParameterSummary {
        Summary("Ask \(\.$question) on \(\.$target)")
    }

    @Parameter(title: "Question")
    public var question: String

    @Parameter(title: "Target", default: nil)
    public var target: SparkTargetEntity?

    public init() {}

    public init(question: String, target: SparkTargetEntity? = nil) {
        self.question = question
        self.target = target
    }

    public func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog
    {
        let answer = try await choosingSpark($target) {
            try await IntentServices.shared.ask(question, targetID: target?.id)
        }
        return spokenResult(answer)
    }
}

/// "Summarise Text with Spark" (§40.2).
public struct SummarizeWithSparkIntent: AppIntent {
    public static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    public static let title: LocalizedStringResource = "Summarise with Spark"
    public static let description = IntentDescription(
        "Summarise text with your private Spark model."
    )

    public static let openAppWhenRun = false
    public static let isDiscoverable = true

    public static var parameterSummary: some ParameterSummary {
        Summary("Summarise \(\.$text) on \(\.$target)")
    }

    @Parameter(title: "Text")
    public var text: String

    @Parameter(title: "Target", default: nil)
    public var target: SparkTargetEntity?

    public init() {}

    public init(text: String, target: SparkTargetEntity? = nil) {
        self.text = text
        self.target = target
    }

    public func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog
    {
        let summary = try await choosingSpark($target) {
            try await IntentServices.shared.transform(text, kind: .summarise, targetID: target?.id)
        }
        return spokenResult(summary)
    }
}

/// "Rewrite Text with Spark" (§40.2).
public struct RewriteWithSparkIntent: AppIntent {
    public static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    public static let title: LocalizedStringResource = "Rewrite with Spark"
    public static let description = IntentDescription(
        "Rewrite text with your private Spark model."
    )

    public static let openAppWhenRun = false
    public static let isDiscoverable = true

    public static var parameterSummary: some ParameterSummary {
        Summary("Rewrite \(\.$text) on \(\.$target)")
    }

    @Parameter(title: "Text")
    public var text: String

    @Parameter(title: "Target", default: nil)
    public var target: SparkTargetEntity?

    public init() {}

    public init(text: String, target: SparkTargetEntity? = nil) {
        self.text = text
        self.target = target
    }

    public func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog
    {
        let rewritten = try await choosingSpark($target) {
            try await IntentServices.shared.transform(text, kind: .rewrite, targetID: target?.id)
        }
        return spokenResult(rewritten)
    }
}

/// Return concise spoken Spark status without loading a model (§40.4).
public struct CheckSparkStatusIntent: AppIntent {
    public static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    public static let title: LocalizedStringResource = "Check Spark Status"
    public static let description = IntentDescription(
        "Hear how your Spark is doing: connection, loaded model, memory, jobs."
    )

    public static let openAppWhenRun = false
    public static let isDiscoverable = true

    public static var parameterSummary: some ParameterSummary {
        Summary("Check \(\.$target)")
    }

    @Parameter(title: "Target", default: nil)
    public var target: SparkTargetEntity?

    public init() {}

    public init(target: SparkTargetEntity? = nil) {
        self.target = target
    }

    public func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog
    {
        let snapshot = try await choosingSpark($target) {
            try await IntentServices.shared.status(targetID: target?.id)
        }
        let summary = snapshot.spokenSummary
        return .result(
            value: summary,
            dialog: IntentDialog(
                full: LocalizedStringResource(stringLiteral: summary),
                supporting: ""
            )
        )
    }
}

/// "Load Spark Model" — durable load, job identifier back (§40.3).
public struct LoadSparkModelIntent: AppIntent {
    public static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    public static let title: LocalizedStringResource = "Load Spark Model"
    public static let description = IntentDescription(
        "Load an installed model onto your Spark."
    )

    public static let openAppWhenRun = false
    public static let isDiscoverable = true

    public static var parameterSummary: some ParameterSummary {
        Summary("Load \(\.$model)")
    }

    @Parameter(title: "Model")
    public var model: SparkModelEntity?

    public init() {}

    public init(model: SparkModelEntity?) {
        self.model = model
    }

    public func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog
    {
        guard let model else {
            throw $model.needsValueError(IntentDialog("Which model should your Spark load?"))
        }
        guard model.installed else {
            throw SparkIntentError.modelNotInstalled(modelID: model.displayName)
        }
        guard model.canLoad else {
            throw SparkIntentError.permissionDenied
        }
        let operationID = try await IntentServices.shared.loadModel(
            model.modelID,
            targetID: model.targetID
        )
        let message = String(localized: .loadingModelCheckBack(model.displayName))
        return .result(
            value: operationID,
            dialog: IntentDialog(
                full: LocalizedStringResource(stringLiteral: message),
                supporting: ""
            )
        )
    }
}

/// "Unload Active Model" — durable unload, job identifier back (§40.2).
public struct UnloadActiveModelIntent: AppIntent {
    public static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    public static let title: LocalizedStringResource = "Unload Active Model"
    public static let description = IntentDescription(
        "Free your Spark's memory by stopping the active model."
    )

    public static let openAppWhenRun = false
    public static let isDiscoverable = true

    public static var parameterSummary: some ParameterSummary {
        Summary("Unload the model on \(\.$target)")
    }

    @Parameter(title: "Target", default: nil)
    public var target: SparkTargetEntity?

    public init() {}

    public init(target: SparkTargetEntity? = nil) {
        self.target = target
    }

    public func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog
    {
        let operationID = try await choosingSpark($target) {
            try await IntentServices.shared.unloadActiveModel(targetID: target?.id)
        }
        let message = String(
            localized: "Stopping the active model. Memory frees once it verifies the stop."
        )
        return .result(
            value: operationID,
            dialog: IntentDialog(
                full: LocalizedStringResource(stringLiteral: message),
                supporting: ""
            )
        )
    }
}

/// A draft returned to the caller; this intent never sends a message.
public struct DraftReplyWithSparkIntent: AppIntent {
    public static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    public static let title: LocalizedStringResource = "Draft Reply with Spark"
    public static let description = IntentDescription(
        "Draft a reply to text you share with your Spark; nothing is sent."
    )

    public static let openAppWhenRun = false
    public static let isDiscoverable = true

    public static var parameterSummary: some ParameterSummary {
        Summary("Draft a reply to \(\.$text) on \(\.$target)")
    }
    @Parameter(title: "Message") public var text: String
    @Parameter(title: "Target", default: nil) public var target: SparkTargetEntity?
    public init() {}
    public init(text: String, target: SparkTargetEntity? = nil) {
        self.text = text
        self.target = target
    }
    public func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog
    {
        let reply = try await choosingSpark($target) {
            try await IntentServices.shared.transform(text, kind: .draftReply, targetID: target?.id)
        }
        return spokenResult(reply)
    }
}

public struct DraftEmailWithSparkIntent: AppIntent {
    public static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    public static let title: LocalizedStringResource = "Draft Email with Spark"
    public static let description = IntentDescription(
        "Draft an email with your private Spark model for you to review."
    )

    public static let openAppWhenRun = false
    public static let isDiscoverable = true

    public static var parameterSummary: some ParameterSummary {
        Summary("Draft an email from \(\.$text) on \(\.$target)")
    }
    @Parameter(title: "Email brief") public var text: String
    @Parameter(title: "Target", default: nil) public var target: SparkTargetEntity?
    public init() {}
    public init(text: String, target: SparkTargetEntity? = nil) {
        self.text = text
        self.target = target
    }
    public func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog
    {
        let draft = try await choosingSpark($target) {
            try await IntentServices.shared.transform(text, kind: .draftEmail, targetID: target?.id)
        }
        return spokenResult(draft)
    }
}

/// Let the system collect the missing Spark instead of ending the shortcut, because "choose a Spark" is a question Siri and Shortcuts can ask.
private func choosingSpark<Value>(
    _ target: IntentParameter<SparkTargetEntity?>,
    _ body: () async throws -> Value
) async throws -> Value {
    do {
        return try await body()
    } catch SparkIntentError.targetRequired {
        throw target.needsValueError(IntentDialog("Which Spark should run this?"))
    }
}

private func spokenResult(_ text: String) -> some IntentResult & ReturnsValue<String>
    & ProvidesDialog
{
    .result(
        value: text,
        dialog: IntentDialog(full: LocalizedStringResource(stringLiteral: text), supporting: "")
    )
}
