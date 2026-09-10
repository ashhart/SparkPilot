#if DEBUG
    import Foundation
    import SparkAPI
    import SparkCore
    import SparkDesignSystem
    import SparkLanguageModel
    import SwiftUI

    /// Local sample data for exercising real views; never pairs, installs software, or reads a saved chat.
    @MainActor
    struct SparkFamilyPreview: View {
        @State private var workspace: SparkChatWorkspace?
        @State private var showsHousehold = false
        @State private var launch: SparkQuickLaunchModel?
        @State private var showsWebSetup = false
        @State private var finishedWebSetup = false
        @State private var voicePreview = false
        @State private var voicePreviewSession: SparkVoiceSession?
        @State private var tailscale: RemoteAccessModel?
        private let household = FamilyPreviewHousehold()

        var body: some View {
            List {
                Section {
                    Text("Preview uses invented data held in memory. Nothing here runs on a Spark.")
                }
                Section("Chat rendering and recovery") {
                    Button("New conversation") {
                        workspace = makeWorkspace(long: false)
                    }
                    Button("Conversation with photo support") {
                        workspace = makeWorkspace(long: false, vision: true)
                    }
                    Button("Restore a long reply") {
                        workspace = makeWorkspace(long: true)
                    }
                    Button("Restore six messages") {
                        workspace = makeWorkspace(long: false, messageCount: 6)
                    }
                    Button("Restore 80 messages") {
                        workspace = makeWorkspace(long: false, messageCount: 80)
                    }
                    Button("Retry after connection loss") {
                        workspace = makeWorkspace(long: false, failFirst: true)
                    }
                }
                Section("Setup and model launch") {
                    NavigationLink("Spark overview preview") { FamilyPreviewDashboard() }
                    Button("Voice controls preview") {
                        voicePreviewSession = makeVoiceControlsPreview()
                        voicePreview = true
                    }
                    Button("Speaking controls preview") {
                        voicePreviewSession = makeVoiceControlsPreview(speaking: true)
                        voicePreview = true
                    }
                    NavigationLink("Harness choices") { SparkDevelopmentHarnessPreview() }
                    Button("Reset preview tips") {
                        for kind in SparkContextTip.Kind.allCases {
                            UserDefaults.standard.removeObject(forKey: kind.dismissalKey)
                        }
                    }
                    NavigationLink("Setup finishing touches") {
                        FamilyPreviewSetupPolish()
                    }
                    Button("Tailscale controls") { tailscale = FamilyPreviewTailscale.model() }
                    Button("Web access during setup") { showsWebSetup = true }
                    if finishedWebSetup { Text("Setup finished") }
                    Button("Launch a saved preset") { launch = FamilyPreviewModelLauncher.model() }
                }
                Section("Family sharing") {
                    Button("Household notes") { showsHousehold = true }
                }
            }
            .navigationTitle("Family flow preview")
            .navigationDestination(
                isPresented: Binding(get: { workspace != nil }, set: { if !$0 { workspace = nil } })
            ) {
                if let workspace {
                    SparkChatView(workspace: workspace)
                        .safeAreaInset(edge: .top, spacing: 0) {
                            HStack {
                                Text("Preview · sample data").font(.caption)
                                Spacer()
                                Button("Close preview") { self.workspace = nil }
                            }.padding(12).background(.thinMaterial)
                        }
                }
            }
            .navigationDestination(
                isPresented: Binding(get: { tailscale != nil }, set: { if !$0 { tailscale = nil } })
            ) {
                if let tailscale {
                    RemoteAccessSettingsView(model: tailscale)
                        .safeAreaInset(edge: .top) {
                            Text("Preview · sample data").font(.caption).padding(8)
                                .frame(maxWidth: .infinity).background(.bar)
                        }
                }
            }
            #if os(iOS)
                .fullScreenCover(isPresented: $voicePreview) {
                    if let voicePreviewSession {
                        SparkVoiceChatView(previewSession: voicePreviewSession)
                    }
                }
            #else
                .sheet(isPresented: $voicePreview) {
                    if let voicePreviewSession {
                        SparkVoiceChatView(previewSession: voicePreviewSession)
                    }
                }
            #endif
            .sheet(item: $launch) { SparkQuickLaunchView(model: $0) }
            .sheet(isPresented: $showsWebSetup) {
                let target = SparkVoiceTarget(FamilyPreviewModelLauncher.target)
                SparkWebAccessSetupView(
                    target: target,
                    settings: FamilyPreviewWebAccess.model(for: target)
                ) {
                    showsWebSetup = false
                    finishedWebSetup = true
                }
            }
            .sheet(isPresented: $showsHousehold) {
                SparkHouseholdView(sparkName: "Sample household", service: household) { _ in }
            }
        }

        private func makeVoiceControlsPreview(speaking: Bool = false) -> SparkVoiceSession {
            let chat = makeWorkspace(long: false).selected.model
            let session = SparkVoiceSession(
                chat: chat,
                dictationOnly: false,
                conversation: true,
                initialTarget: chat.voiceTargets.first,
                outputPreference: .device
            )
            session.phase = speaking ? .speaking : .listening
            session.transcript = String(
                localized: "Plan a simple family meal for Saturday and make a shopping list."
            )
            session.level = 0.6
            return session
        }

        private func makeWorkspace(
            long: Bool,
            messageCount: Int = 0,
            failFirst: Bool = false,
            vision: Bool = false
        )
            -> SparkChatWorkspace
        {
            let target = SparkChatTarget(
                id: "family-preview",
                displayName: "Sample family Spark",
                nodeID: .init(rawValue: UUID()),
                route: URL(string: "https://family-preview.invalid")!,
                tlsFingerprint: "sample",
                authorityFingerprint: "sample",
                modelID: "sample-model",
                modelName: "Sample model",
                contextLength: 32_768,
                visionSupported: vision
            )
            let chat = SparkChatModel(
                catalogue: .init(targets: [target], pairedTargetCount: 1),
                streamer: FamilyPreviewStream(failFirst: failFirst)
            )
            chat.usesSampleData = true
            SparkChatWebAccess.shared.updatePolicy(.off, targetID: target.id)
            let messages: [SparkChatMessage]
            if long {
                let paragraph =
                    "Start with one small task and check what you need. Write down the things that matter, leave room to change the plan, and ask for help when you need it."
                messages = [
                    .init(role: .user, content: "Help me plan a useful week."),
                    .init(
                        role: .assistant,
                        content: (1...45).map { "Step \($0)\n\n\(paragraph)" }.joined(
                            separator: "\n\n"
                        ) + "\n\nEnd of restored reply."
                    ),
                ]
            } else if messageCount > 0 {
                messages = (1...messageCount).map {
                    .init(
                        role: $0.isMultiple(of: 2) ? .assistant : .user,
                        content:
                            "Message \($0): a short part of a saved family planning conversation."
                    )
                }
            } else {
                messages = []
            }
            let record = SparkChatRecord(
                id: UUID(),
                title: long
                    ? "A useful week"
                    : messageCount > 0 ? String(localized: "Saved conversation") : nil,
                updatedAt: Date(),
                targetID: target.id,
                draft: "",
                messages: messages,
                modelID: target.modelID
            )
            let store = FamilyPreviewChatStore(
                archive: .init(selectedID: record.id, conversations: [record])
            )
            return SparkChatWorkspace(initialModel: chat, store: store)
        }
    }

    /// Exercises the shipping optional-name control without pairing or changing a real Spark.
    private struct FamilyPreviewSetupPolish: View {
        @State private var name = ""
        @State private var finished = false

        var body: some View {
            if finished {
                Text("Setup preview finished")
            } else {
                RetailOnboardingView(
                    state: .init(phase: .starterModel),
                    setupSSID: .constant(""),
                    setupPassphrase: .constant(""),
                    customLabel: $name,
                    aiPreparation: ["runtime-health", "vllm", "catalogue"].map {
                        RetailPreparationItem(
                            id: $0,
                            title: String(localized: "Sample check"),
                            detail: String(localized: "Preview only"),
                            status: .ready
                        )
                    },
                    onPrimary: { finished = true }
                )
                .safeAreaInset(edge: .top) {
                    Text("Preview · sample data").font(.caption).padding(8)
                }
            }
        }
    }

    @MainActor
    private final class FamilyPreviewChatStore: SparkChatStoring {
        var archive: SparkChatArchive
        init(archive: SparkChatArchive) { self.archive = archive }
        func load() -> SparkChatArchive { archive }
        func save(_ archive: SparkChatArchive) { self.archive = archive }
    }

    private actor FamilyPreviewStream: SparkChatStreaming {
        var failFirst: Bool
        init(failFirst: Bool) { self.failFirst = failFirst }
        func stream(target: SparkChatTarget, request: ChatCompletionRequest) throws
            -> AsyncThrowingStream<ChatStreamEvent, any Error>
        {
            if failFirst {
                failFirst = false
                throw URLError(.networkConnectionLost)
            }
            let answer =
                "This is a sample reply for checking the app.\n\nLet's plan three simple meals, make a shopping list, and leave one evening free. You can change the plan before saving anything.\n\n| Day | Plan |\n| --- | --- |\n| Monday | Pasta and vegetables |\n| Tuesday | Soup and bread |\n| Wednesday | Baked potatoes |\n\nWhat would you like to change?"
            return AsyncThrowingStream { continuation in
                let task = Task {
                    do {
                        for word in answer.split(separator: " ", omittingEmptySubsequences: false) {
                            try Task.checkCancellation()
                            continuation.yield(
                                .chunk(
                                    id: nil,
                                    model: target.modelID,
                                    delta: String(word) + " ",
                                    finishReason: nil
                                )
                            )
                            try await Task.sleep(for: .milliseconds(70))
                        }
                        continuation.yield(
                            .chunk(id: nil, model: target.modelID, delta: "", finishReason: "stop")
                        )
                        continuation.yield(.done)
                        continuation.finish()
                    } catch { continuation.finish(throwing: error) }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
    }

    private actor FamilyPreviewHousehold: SparkHouseholdProviding {
        var value = GeneratedAPI.HouseholdSnapshot(
            notes: [
                .init(
                    id: UUID().uuidString,
                    title: "Favourite meals",
                    body:
                        "Pat likes vegetable pasta. Sam enjoys soup. Ask everyone before making the shopping list.",
                    revision: 1,
                    authorName: "Pat",
                    updatedByName: "Pat",
                    createdAt: "2026-09-05T12:00:00Z",
                    updatedAt: "2026-09-05T12:00:00Z",
                    canEdit: true
                )
            ],
            members: [
                .init(
                    deviceId: UUID().uuidString,
                    name: "Pat's iPhone",
                    joined: true,
                    administrator: true
                ),
                .init(
                    deviceId: UUID().uuidString,
                    name: "Sam's iPad",
                    joined: false,
                    administrator: false
                ),
            ],
            canManageMembers: true
        )
        func snapshot() -> GeneratedAPI.HouseholdSnapshot { value }
        func save(_ request: GeneratedAPI.HouseholdNoteRequest, key: UUID) {
            value.notes.removeAll { $0.id == request.id }
            if !request.delete {
                value.notes.insert(
                    .init(
                        id: request.id,
                        title: request.title,
                        body: request.body,
                        revision: request.expectedRevision + 1,
                        authorName: "Pat",
                        updatedByName: "Pat",
                        createdAt: "2026-09-05T12:00:00Z",
                        updatedAt: "2026-09-05T12:00:00Z",
                        canEdit: true
                    ),
                    at: 0
                )
            }
        }
        func setMember(_ request: GeneratedAPI.HouseholdMemberRequest, key: UUID) {
            if let index = value.members.firstIndex(where: { $0.deviceId == request.deviceId }) {
                value.members[index].joined = request.joined
            }
        }
    }
#endif
