import Foundation
import SparkIntents

enum SparkAppleAction: String, CaseIterable, Identifiable {
    case ask, status, summarise, rewrite, draftReply, draftEmail, analyseFile, getAnalysis,
        loadModel,
        unloadModel
    var id: String { rawValue }

    var title: String {
        switch self {
        case .ask: String(localized: AskSparkIntent.title)
        case .status: String(localized: CheckSparkStatusIntent.title)
        case .summarise: String(localized: SummarizeWithSparkIntent.title)
        case .rewrite: String(localized: RewriteWithSparkIntent.title)
        case .draftReply: String(localized: DraftReplyWithSparkIntent.title)
        case .draftEmail: String(localized: DraftEmailWithSparkIntent.title)
        case .analyseFile: String(localized: AnalyseFileWithSparkIntent.title)
        case .getAnalysis: String(localized: GetSparkAnalysisIntent.title)
        case .loadModel: String(localized: LoadSparkModelIntent.title)
        case .unloadModel: String(localized: UnloadActiveModelIntent.title)
        }
    }

    var detail: String {
        switch self {
        case .ask:
            String(
                localized: "Ask your Spark a question and get an answer for Siri or another action."
            )
        case .status:
            String(localized: "Check connection, the loaded model, memory and waiting jobs.")
        case .summarise: String(localized: "Turn supplied text into a shorter summary.")
        case .rewrite: String(localized: "Rewrite supplied text while keeping its meaning.")
        case .draftReply: String(localized: "Prepare reply text to review or pass to another app.")
        case .draftEmail:
            String(
                localized: "Draft an email subject and body to review before opening your mail app."
            )
        case .analyseFile:
            String(localized: "Analyse a selected text file, including JSON, YAML and source code.")
        case .getAnalysis:
            String(localized: "Collect an analysis using the job ID returned by your Spark.")
        case .loadModel: String(localized: "Start an installed model and return its operation ID.")
        case .unloadModel: String(localized: "Stop the active model and return its operation ID.")
        }
    }

    var symbol: String {
        switch self {
        case .ask: "bubble.left.and.text.bubble.right"
        case .status: "stethoscope"
        case .summarise: "text.document"
        case .rewrite: "character.cursor.ibeam"
        case .draftReply: "message"
        case .draftEmail: "envelope"
        case .analyseFile: "doc.text.magnifyingglass"
        case .getAnalysis: "tray.and.arrow.down"
        case .loadModel: "arrow.down.circle"
        case .unloadModel: "stop.circle"
        }
    }

    var changesModel: Bool { self == .loadModel || self == .unloadModel }
    var requiresText: Bool {
        [.ask, .summarise, .rewrite, .draftReply, .draftEmail, .analyseFile, .getAnalysis].contains(
            self
        )
    }
    var permission: IntentTargetAction {
        self == .status ? .readStatus : changesModel ? .operateModels : .runInference
    }
    var inputLabel: String {
        switch self {
        case .ask: String(localized: "Question")
        case .analyseFile: String(localized: "Instruction")
        case .getAnalysis: String(localized: "Job ID")
        default: String(localized: "Text")
        }
    }
}
