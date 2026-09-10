import AppIntents
import SparkIntents

struct SparkPilotShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskSparkIntent(),
            phrases: [
                "Ask \(.applicationName) a question",
                "Ask Spark in \(.applicationName)",
                "Ask my Spark in \(.applicationName)",
            ],
            shortTitle: "Ask Spark",
            systemImageName: "bubble.left.and.text.bubble.right"
        )
        AppShortcut(
            intent: CheckSparkStatusIntent(),
            phrases: [
                "Check my Spark in \(.applicationName)",
                "How is my Spark in \(.applicationName)",
                "Is my Spark online in \(.applicationName)",
            ],
            shortTitle: "Check Spark",
            systemImageName: "stethoscope"
        )
        AppShortcut(
            intent: SummarizeWithSparkIntent(),
            phrases: [
                "Summarise with \(.applicationName)",
                "Summarise this with \(.applicationName)",
                "Give me the short version with \(.applicationName)",
            ],
            shortTitle: "Summarise",
            systemImageName: "text.document"
        )
        AppShortcut(
            intent: RewriteWithSparkIntent(),
            phrases: [
                "Rewrite text with \(.applicationName)",
                "Rewrite this with \(.applicationName)",
                "Say this better with \(.applicationName)",
            ],
            shortTitle: "Rewrite",
            systemImageName: "character.cursor.ibeam"
        )
        AppShortcut(
            intent: DraftReplyWithSparkIntent(),
            phrases: [
                "Draft a reply with \(.applicationName)",
                "Write a reply with \(.applicationName)",
                "Help me reply with \(.applicationName)",
            ],
            shortTitle: "Draft Reply",
            systemImageName: "message"
        )
        AppShortcut(
            intent: DraftEmailWithSparkIntent(),
            phrases: [
                "Draft an email with \(.applicationName)",
                "Write an email with \(.applicationName)",
                "Help me write an email with \(.applicationName)",
            ],
            shortTitle: "Draft Email",
            systemImageName: "envelope"
        )
        AppShortcut(
            intent: AnalyseFileWithSparkIntent(),
            phrases: [
                "Analyse a file with \(.applicationName)",
                "Read a file with \(.applicationName)",
                "Look at this file with \(.applicationName)",
            ],
            shortTitle: "Read a File",
            systemImageName: "doc.text.magnifyingglass"
        )
        AppShortcut(
            intent: GetSparkAnalysisIntent(),
            phrases: [
                "Get a Spark analysis in \(.applicationName)",
                "What did my Spark make of my file in \(.applicationName)",
                "Show my file analysis in \(.applicationName)",
            ],
            shortTitle: "File Findings",
            systemImageName: "tray.and.arrow.down"
        )
        AppShortcut(
            intent: LoadSparkModelIntent(model: nil),
            phrases: [
                "Load a model in \(.applicationName)",
                "Start a model in \(.applicationName)",
                "Get a model ready in \(.applicationName)",
            ],
            shortTitle: "Start a Model",
            systemImageName: "arrow.down.circle"
        )
        AppShortcut(
            intent: UnloadActiveModelIntent(),
            phrases: [
                "Unload the active model in \(.applicationName)",
                "Stop the model in \(.applicationName)",
                "Free up my Spark in \(.applicationName)",
            ],
            shortTitle: "Stop the Model",
            systemImageName: "stop.circle"
        )
    }
}
