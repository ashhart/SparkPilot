import SparkAPI
import SwiftUI

/// The Spark-side decision: whether the model may read the internet at all, and who may ask it to.
public struct SparkWebAccessSection: View {
    @Bindable var model: SparkAutomationsModel
    @State private var policy: GeneratedAPI.WebAccessSettingsPolicy = .off
    @State private var credentialID = ""
    @State private var credentialName = ""
    @State private var credentialSecret = ""
    @State private var addingKey = false
    @State private var harnessAccess = false
    @State private var backend: GeneratedAPI.WebAccessSettingsSearchBackend = .searxng

    public init(model: SparkAutomationsModel) {
        self.model = model
    }

    public var body: some View {
        Section("Model internet access") {
            Picker("Allow", selection: $policy) {
                Text("Off").tag(GeneratedAPI.WebAccessSettingsPolicy.off)
                Text("Automations only").tag(GeneratedAPI.WebAccessSettingsPolicy.automations)
                Text("Automations and chats")
                    .tag(GeneratedAPI.WebAccessSettingsPolicy.automationsAndChats)
            }
            .accessibilityIdentifier("spark.web.policy")
            Text(
                "This is a setting on your Spark, not on this phone. Each automation and each conversation still has its own switch, and neither can go further than this."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
            Picker("Search with", selection: $backend) {
                Text("Your Spark's own search")
                    .tag(GeneratedAPI.WebAccessSettingsSearchBackend.searxng)
                Text("DuckDuckGo").tag(GeneratedAPI.WebAccessSettingsSearchBackend.duckduckgo)
                Text("Brave, with your key").tag(GeneratedAPI.WebAccessSettingsSearchBackend.brave)
                Text("No searching").tag(GeneratedAPI.WebAccessSettingsSearchBackend.disabled)
            }
            .accessibilityIdentifier("spark.web.backend")
            if backend == .brave { braveKeyControls }
            Text(backendExplanation)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Toggle("Let other apps on this Spark use it", isOn: $harnessAccess)
                .disabled(policy != .automationsAndChats)
                .accessibilityIdentifier("spark.web.harness")
            Text(
                "Off unless you turn it on. Apps that talk to your Spark's OpenAI-compatible address never get to search or read pages by accident."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
            Button(needsRepair && unchanged ? "Repair search" : "Save internet setting") {
                Task {
                    await model.setWebAccess(
                        policy: policy,
                        harnessAccess: harnessAccess,
                        backend: backend,
                        braveCredentialID: credentialID.isEmpty ? nil : credentialID
                    )
                }
            }
            .disabled(
                !model.isOwner || model.isChanging || (unchanged && !needsRepair)
                    || model.webAccess == nil
                    || (backend == .brave && credentialID.isEmpty)
            )
            .accessibilityIdentifier("spark.web.save")
            if model.isChanging {
                ProgressView(String(localized: "Saving internet access on your Spark…"))
            }
        }
        .onChange(of: model.webAccess) { _, settings in adopt(settings) }
        .onAppear { adopt(model.webAccess) }
    }

    private var needsRepair: Bool {
        backend == .searxng && policy != .off && model.webAccess?.localSearchState != .running
    }

    @ViewBuilder private var braveKeyControls: some View {
        Picker("Search key", selection: $credentialID) {
            Text("Choose a saved key").tag("")
            ForEach(model.searchCredentials, id: \.id) { credential in
                Text(credential.displayName).tag(credential.id)
            }
        }
        .accessibilityIdentifier("spark.web.credential")
        DisclosureGroup(String(localized: "Add a Brave Search key"), isExpanded: $addingKey) {
            TextField("Key name", text: $credentialName)
            SecureField("Brave Search API key", text: $credentialSecret)
                .autocorrectionDisabled()
                .accessibilityIdentifier("spark.web.secret")
            Button("Save key on Spark") {
                Task {
                    if let id = await model.addSearchCredential(
                        name: credentialName,
                        secret: credentialSecret
                    ) {
                        credentialID = id
                        credentialSecret = ""
                        addingKey = false
                    }
                }
            }
            .disabled(
                !model.isOwner || model.isChanging
                    || credentialSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
            Link("Get a key from Brave", destination: URL(string: "https://api.search.brave.com/")!)
        }
    }

    private var unchanged: Bool {
        guard let current = model.webAccess else { return false }
        return current.policy == policy && current.harnessAccess == harnessAccess
            && current.searchBackend == backend && (current.braveCredentialId ?? "") == credentialID
    }

    private var backendExplanation: String {
        switch backend {
        case .searxng:
            switch model.webAccess?.localSearchState {
            case .some(.running):
                String(
                    localized:
                        "Your Spark runs the search service and sends search words to its search providers without an account."
                )
            case .some(.notInstalled), .none:
                String(
                    localized:
                        "Saving this installs a small search service on your Spark. Search words are sent to its search providers without an account."
                )
            case .some(.unhealthy):
                String(
                    localized:
                        "Your Spark's own search is installed but not answering. Saving again reinstalls it."
                )
            case .some(.unknown):
                String(localized: "Your Spark's own search. Your searches carry no account.")
            }
        case .duckduckgo:
            String(
                localized:
                    "No account and no key, but your search words reach DuckDuckGo rather than staying in the house."
            )
        case .brave:
            String(
                localized:
                    "Your search words and your own Brave key reach Brave. The key stays on your Spark."
            )
        case .disabled:
            String(
                localized:
                    "No searching. Your Spark can still read a page whose address it is given."
            )
        }
    }

    private func adopt(_ settings: GeneratedAPI.WebAccessSettings?) {
        guard let settings else { return }
        policy = settings.policy
        harnessAccess = settings.harnessAccess
        backend = settings.searchBackend
        credentialID = settings.braveCredentialId ?? ""
    }
}
