import AppIntents
import SparkIntents
import SparkLanguageModel
import SwiftUI

/// QA-16: the system tip drew an empty grey capsule wherever nothing had donated a phrase; the tip now quotes the phrase this app registers, and stands down if there is none.
enum SparkSiriTip {
    static var spokenPhrase: String? {
        let phrase = String(localized: "Ask SparkPilot a question")
        return phrase.isEmpty ? nil : phrase
    }
}

@MainActor
struct SparkAppleAppsView: View {
    let chat: SparkChatModel
    @State private var showsPersonalActions = false
    @State private var personalRequest = ""
    @State private var intelligence = SparkAppleIntelligence.state
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        List {
            Section {
                SparkContextTip(.shortcuts)
                Text(
                    "Use Siri to ask your Spark, build Shortcuts with its answers, or prepare actions for your Apple apps."
                )
                .font(.body)
                #if os(iOS)
                    // ShortcutsLink lands on this app's own shortcuts; the URL scheme only opens the app, and macOS has no ShortcutsLink.
                    ShortcutsLink()
                    if let phrase = SparkSiriTip.spokenPhrase {
                        Label {
                            Text(phrase)
                        } icon: {
                            Image(systemName: "waveform.circle.fill")
                                .foregroundStyle(.tint)
                        }
                        .font(.callout)
                    }
                #else
                    Link(destination: URL(string: "shortcuts://")!) {
                        Label("Open Shortcuts", systemImage: "square.stack.3d.up")
                    }
                #endif
                LabeledContent("Apple Intelligence", value: intelligence.summary)
                Text(intelligence.explanation)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Siri & Shortcuts")
            }

            Section {
                ForEach(SparkAppleAction.allCases) { action in
                    NavigationLink {
                        SparkIntentActionView(action: action, chat: chat)
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(action.title).font(.headline)
                                Text(action.detail).font(.subheadline).foregroundStyle(.secondary)
                            }.padding(.vertical, 5)
                        } icon: {
                            Image(systemName: action.symbol)
                        }
                    }
                    .accessibilityIdentifier("apple.action.\(action.rawValue)")
                }
            } header: {
                Text("Try a Spark action")
            } footer: {
                Text(
                    "These actions use the same paired Spark connection as Siri and Shortcuts; running them here returns a real result."
                )
            }

            Section {
                personalAction(
                    String(localized: "Calendar event"),
                    symbol: "calendar.badge.plus",
                    request: String(localized: "Help me prepare a calendar event.")
                )
                personalAction(
                    String(localized: "Reminder"),
                    symbol: "checklist",
                    request: String(localized: "Help me prepare a reminder.")
                )
                personalAction(
                    String(localized: "Message draft"),
                    symbol: "message",
                    request: String(localized: "Help me draft a message.")
                )
                Button {
                    personalRequest = ""
                    showsPersonalActions = true
                } label: {
                    Label("Prepare multiple actions", systemImage: "list.bullet.clipboard")
                }
                NavigationLink {
                    SparkPersonalShortcutView(text: "")
                } label: {
                    Label("Run a Shortcut", systemImage: "arrow.triangle.branch")
                }
            } header: {
                Text("Work with Apple apps")
            } footer: {
                Text(
                    "Review drafts before saving in Calendar or Reminders, sending in Mail or Messages, or handing text to a Shortcut."
                )
            }
            Section {
                ForEach(SparkAppleWorkflow.allCases) { workflow in
                    NavigationLink {
                        SparkPersonalShortcutView(text: "", workflow: workflow.purpose)
                            .navigationTitle(workflow.title)
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(workflow.title)
                                Text("Via Shortcuts").font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: workflow.symbol)
                        }
                    }
                }
            } header: {
                Text("More Apple app workflows")
            } footer: {
                Text(
                    "Use a Shortcut you create or trust; available actions depend on this device and its installed apps, and each app controls its own permissions."
                )
            }
        }
        .navigationTitle("Siri & Apple Apps")
        // Apple Intelligence can be switched on, or finish preparing, while this screen is in the background.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            intelligence = SparkAppleIntelligence.state
        }
        .sheet(isPresented: $showsPersonalActions) {
            SparkPersonalActionsView(chat: chat, request: personalRequest)
        }
    }

    private func personalAction(_ title: String, symbol: String, request: String) -> some View {
        Button {
            personalRequest = request
            showsPersonalActions = true
        } label: {
            Label(title, systemImage: symbol)
        }
    }
}
