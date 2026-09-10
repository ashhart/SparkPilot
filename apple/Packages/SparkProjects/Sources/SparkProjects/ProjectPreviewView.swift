import SwiftUI

/// PLAN 42.7's preview pane: the project's own dev server, read through the signed proxy.
@MainActor
struct ProjectPreviewView: View {
    @Bindable var model: ProjectsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            controls
            Divider()
            content
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onDisappear { model.clearPreview() }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("Port", text: $model.previewPort)
                    .frame(maxWidth: 90)
                    .accessibilityLabel("Port the project serves on")
                TextField("Path", text: $model.previewPath, prompt: Text(verbatim: "index.html"))
                    .accessibilityLabel("Path within the previewed service")
                Button("Load Preview") { Task { await model.loadPreview() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canPreview || model.previewState == .loading)
            }
            .textFieldStyle(.roundedBorder)
            #if os(iOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            #endif
            if let origin = model.previewOrigin {
                HStack(spacing: 4) {
                    Text("Served from")
                    Text(verbatim: origin)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            if !model.canPreview {
                Text("This project does not offer a preview to this device.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch model.previewState {
        case .idle:
            ContentUnavailableView(
                "Nothing loaded yet",
                systemImage: "safari",
                description: Text(
                    "Start your project's own server in the Terminal, then load its port here."
                )
            )
        case .loading:
            ProgressView(String(localized: "Reading the preview…"))
                .accessibilityLabel("Reading the preview")
        case .empty:
            ContentUnavailableView(
                "The page was empty",
                systemImage: "doc",
                description: Text("The service answered with nothing at that path.")
            )
        case .failed(let message):
            ProjectFailureView(message: message) { await model.loadPreview() }
        case .loaded:
            ScrollView([.vertical, .horizontal]) {
                Text(verbatim: model.previewBody)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityLabel("Preview response")
        }
    }
}
