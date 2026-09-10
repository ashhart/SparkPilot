import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
    import PhotosUI
#endif

@MainActor
public struct SparkBugFeedbackView: View {
    @AppStorage("sparkpilot.feedback.draft.v1") private var savedDraft = Data()
    @State private var draft = SparkBugDraft()
    @State private var screenshot: SparkBugScreenshot?
    @State private var reviewedReport: SparkBugReport?
    @State private var loadedDraft = false
    @State private var confirmDiscard = false
    @State private var attachmentError: String?
    @State private var isReadingImage = false
    @State private var showsImageFiles = false
    #if os(iOS)
        @State private var photo: PhotosPickerItem?
    #endif
    private let screenshotStore = SparkBugScreenshotStore()

    public init() {}

    public var body: some View {
        Form {
            Section {
                Text("Help us improve SparkPilot.")
                Picker("Type", selection: $draft.kind) {
                    ForEach(SparkFeedbackKind.allCases) { kind in Text(kind.title).tag(kind) }
                }
                TextField(draft.kind.prompt, text: $draft.happened, axis: .vertical)
                    .lineLimit(4...12)
                    .accessibilityIdentifier("spark.feedback.description")
                    .accessibilityHint("Required; describe your feedback in your own words")
                if draft.kind == .bug {
                    TextField("How can we reproduce it?", text: $draft.steps, axis: .vertical)
                        .lineLimit(3...10)
                        .accessibilityHint(
                            "Optional; the steps you took before the problem appeared"
                        )
                }
            } footer: {
                Text("Please leave out passwords, invitation codes and private conversations.")
            }
            Section("Screenshot, if it helps") {
                if let screenshot {
                    SparkBugScreenshotPreview(screenshot: screenshot)
                    Button("Remove screenshot", role: .destructive) {
                        do {
                            try screenshotStore.remove()
                            self.screenshot = nil
                            #if os(iOS)
                                photo = nil
                            #endif
                            attachmentError = nil
                        } catch {
                            attachmentError = String(
                                localized: "The screenshot could not be removed; try again."
                            )
                        }
                    }
                } else {
                    #if os(iOS)
                        PhotosPicker(selection: $photo, matching: .images) {
                            Label("Choose screenshot", systemImage: "photo")
                        }
                    #endif
                    Button("Choose image from Files", systemImage: "folder") {
                        showsImageFiles = true
                    }
                }
                if isReadingImage { ProgressView(String(localized: "Preparing screenshot…")) }
                if let attachmentError { Text(attachmentError).foregroundStyle(.red) }
            }
            .disabled(isReadingImage)
            Section {
                Button("Review report") {
                    guard draft.canReview else { return }
                    reviewedReport = .init(
                        draft: draft,
                        screenshot: screenshot,
                        recipient: SparkBugFeedbackConfiguration.recipient
                    )
                }
                .disabled(!draft.canReview || isReadingImage)
                if draft.hasContent && !draft.canReview {
                    Text("Add a description and keep each answer under 16 KB.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if draft.hasContent || screenshot != nil {
                    Button("Discard draft", role: .destructive) { confirmDiscard = true }
                }
            } footer: {
                Text(
                    "Only your words and chosen screenshot are included; no telemetry or diagnostics are collected, and you review everything before sharing."
                )
            }
            Section {
                Text("Your draft is saved on this device until you discard it.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .privacySensitive()
        .formStyle(.grouped)
        .navigationTitle("Feedback")
        .task {
            guard !loadedDraft else { return }
            if let restored = try? JSONDecoder().decode(SparkBugDraft.self, from: savedDraft) {
                draft = restored
            }
            do { screenshot = try screenshotStore.load() } catch {
                attachmentError = String(
                    localized: "The saved screenshot could not be opened; choose it again."
                )
            }
            loadedDraft = true
        }
        .onChange(of: draft) { _, value in
            guard loadedDraft else { return }
            savedDraft = (try? JSONEncoder().encode(value)) ?? savedDraft
        }
        .alert("Discard this feedback draft?", isPresented: $confirmDiscard) {
            Button("Discard draft", role: .destructive) {
                do {
                    try screenshotStore.remove()
                    draft = .init()
                    screenshot = nil
                    #if os(iOS)
                        photo = nil
                    #endif
                    savedDraft = Data()
                    attachmentError = nil
                } catch {
                    attachmentError = String(
                        localized: "The draft could not be discarded; try again."
                    )
                }
            }
            Button("Keep draft", role: .cancel) {}
        }
        .sheet(item: $reviewedReport) { report in SparkBugReportReview(report: report) }
        .fileImporter(isPresented: $showsImageFiles, allowedContentTypes: [.image]) { result in
            guard case .success(let url) = result else { return }
            let granted = url.startAccessingSecurityScopedResource()
            defer { if granted { url.stopAccessingSecurityScopedResource() } }
            do { try attach(data: SparkBugScreenshot.readBoundedFile(url)) } catch {
                attachmentError = SparkBugScreenshot.failureMessage
            }
        }
        #if os(iOS)
            .task(id: photo) {
                guard let photo else { return }
                isReadingImage = true
                defer {
                    if self.photo == photo {
                        isReadingImage = false
                        self.photo = nil
                    }
                }
                do {
                    guard let data = try await photo.loadTransferable(type: Data.self) else {
                        throw SparkBugScreenshotError.unreadable
                    }
                    try Task.checkCancellation()
                    try attach(data: data)
                } catch is CancellationError {
                } catch { attachmentError = SparkBugScreenshot.failureMessage }
            }
        #endif
    }

    private func attach(data: Data) throws {
        let next = try SparkBugScreenshot(data: data)
        try screenshotStore.save(next)
        screenshot = next
        attachmentError = nil
    }
}

@MainActor
struct SparkBugFeedbackLink: View {
    var body: some View {
        NavigationLink {
            SparkBugFeedbackView()
        } label: {
            SparkNavigationLabel(
                title: String(localized: "Feedback & bug reports"),
                systemImage: "bubble.left.and.text.bubble.right"
            )
        }
    }
}
