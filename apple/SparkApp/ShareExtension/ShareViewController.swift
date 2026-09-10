import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
    import AppKit
    typealias SharePlatformController = NSViewController
#else
    import UIKit
    typealias SharePlatformController = UIViewController
#endif

@MainActor
final class ShareViewController: SharePlatformController {
    private let model = SparkShareModel()
    private var loadTask: Task<Void, Never>?

    override func loadView() {
        let content = SparkShareView(
            model: model,
            finish: { [weak self] in self?.finish() },
            save: { [weak self] in self?.save() },
            replaceOldest: { [weak self] in self?.save(replacingOldest: true) },
            cancel: { [weak self] in
                self?.loadTask?.cancel()
                self?.extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
            }
        )
        #if os(macOS)
            view = NSHostingView(rootView: content)
            preferredContentSize = NSSize(width: 440, height: 440)
        #else
            let host = UIHostingController(rootView: content)
            let container = UIView()
            container.backgroundColor = .systemBackground
            view = container
            addChild(host)
            host.view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(host.view)
            NSLayoutConstraint.activate([
                host.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                host.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                host.view.topAnchor.constraint(equalTo: container.topAnchor),
                host.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
            host.didMove(toParent: self)
            preferredContentSize = CGSize(width: 440, height: 440)
        #endif
        loadTask = Task {
            await model.load(extensionContext?.inputItems as? [NSExtensionItem] ?? [])
        }
    }

    private func save(replacingOldest: Bool = false) {
        guard !model.saving else { return }
        model.saving = true
        model.inboxFull = false
        let share = SparkSharedChat(text: model.text, files: model.files)
        Task {
            defer { model.saving = false }
            do {
                try await Task.detached {
                    try SparkChatInbox.shared().enqueue(
                        share,
                        replacingOldestWhenFull: replacingOldest
                    )
                }.value
                model.saved = true
            } catch {
                if case SparkChatInbox.InboxError.full = error { model.inboxFull = true }
                model.error =
                    (error as? LocalizedError)?.errorDescription
                    ?? String(localized: "The shared content could not be saved.")
            }
        }
    }

    fileprivate func finish() { extensionContext?.completeRequest(returningItems: nil) }
}

private struct SparkShareView: View {
    @Bindable var model: SparkShareModel
    let finish: () -> Void
    let save: () -> Void
    let replaceOldest: () -> Void
    let cancel: () -> Void
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Share with SparkPilot").font(.title2.bold())
                if model.saved {
                    Label("Saved to SparkPilot", systemImage: "checkmark.circle")
                    Text(
                        "Open SparkPilot to review this new chat and choose a model before sending."
                    )
                    Button("Done", action: finish)
                } else if model.saving {
                    ProgressView(String(localized: "Saving shared chat…"))
                } else if model.loading {
                    ProgressView(String(localized: "Reading shared items…"))
                    Button("Cancel", action: cancel)
                } else {
                    TextEditor(text: $model.text).frame(minHeight: 100)
                        .accessibilityLabel(String(localized: "Shared message"))
                    ForEach(Array(model.files.enumerated()), id: \.offset) { _, file in
                        Label(file.name, systemImage: "doc")
                    }
                    if let error = model.error { Text(error).foregroundStyle(.red) }
                    if model.inboxFull {
                        Button("Replace the oldest pending share", action: replaceOldest)
                            .buttonStyle(.bordered)
                    }
                    Text(
                        "Photos require a model with vision enabled; documents are read on your device."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Cancel", action: cancel)
                        Spacer()
                        Button("Save to SparkPilot", action: save)
                            .disabled(
                                model.loadFailed || (model.text.isEmpty && model.files.isEmpty)
                            )
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
            .padding(24)
        }
    }
}
