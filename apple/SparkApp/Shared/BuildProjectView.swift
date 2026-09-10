import SparkAPI
import SwiftUI
import ImageIO

public struct BuildProjectView: View {
    @State private var model: BuildProjectModel

    public init(model: BuildProjectModel) {
        _model = State(initialValue: model)
    }

    public var body: some View {
        @Bindable var model = model
        let visibleBuilds = model.builds.filter { $0.targetID == model.selectedTargetID }
        Form {
            Section {
                switch model.accessGate {
                case .noSparkSaved:
                    ContentUnavailableView(
                        "No Paired Spark",
                        systemImage: "hammer",
                        description: Text("Pair a Spark before submitting an Apple build.")
                    )
                case .noUsableSpark:
                    ContentUnavailableView(
                        "No Spark Signed In Here",
                        systemImage: "person.badge.key",
                        description: Text(
                            "Your Sparks are paired, but this device has no signing or trust record for any of them. Open one from Home to sign in, then come back to Builds."
                        )
                    )
                case .ready:
                    Picker("Build on", selection: $model.selectedTargetID) {
                        ForEach(model.targets) { target in
                            Text(target.name).tag(Optional(target.id))
                        }
                    }
                    .onChange(of: model.selectedTargetID) { _, targetID in
                        Task { await model.selectTarget(targetID) }
                    }
                    if model.isLoading {
                        ProgressView(String(localized: "Loading projects"))
                    } else if model.projects.isEmpty {
                        Text("No buildable projects are available to this device.")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Project", selection: $model.selectedProjectID) {
                            ForEach(model.projects, id: \.id) { project in
                                Text(project.name).tag(Optional(project.id))
                            }
                        }
                    }
                }
            } header: {
                Text("Project")
            } footer: {
                Text("The selected Spark assigns work only to an opted-in paired Mac.")
            }

            Section("Immutable source") {
                TextField("40-character Git commit", text: $model.commit)
                TextField("64-character source SHA-256", text: $model.sourceSHA256)
            }

            Section("Xcode recipe") {
                TextField("Scheme", text: $model.scheme)
                TextField("Configuration", text: $model.configuration)
                TextField("Destination", text: $model.destination)
                Toggle("Run tests", isOn: $model.runsTests)
                Button {
                    Task { await model.submit() }
                } label: {
                    if model.isSubmitting {
                        ProgressView()
                    } else {
                        Label("Queue Build", systemImage: "hammer.fill")
                    }
                }
                .disabled(!model.canSubmit)
                // QA-13: say what the disabled button is still waiting for.
                if let reason = model.submitBlockReason {
                    Text(reason)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if let problem = model.problem {
                Section { Label(problem, systemImage: "exclamationmark.triangle.fill") }
                    .foregroundStyle(.orange)
            }

            Section("Builds") {
                if visibleBuilds.isEmpty {
                    Text("Queued and completed builds appear here and survive relaunch.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(visibleBuilds) { build in
                        BuildResultRow(build: build) { artifact in
                            try await model.screenshotData(build: build, artifact: artifact)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Builds")
        .toolbar {
            Button("Refresh", systemImage: "arrow.clockwise") {
                Task { await model.refreshProjects() }
            }
        }
        .task {
            model.refreshTargets()
            await model.refreshProjects()
        }
    }
}

private struct BuildResultRow: View {
    let build: SavedBuild
    let loadScreenshot: (SavedBuildArtifact) async throws -> Data

    var body: some View {
        DisclosureGroup {
            LabeledContent("Build", value: build.id)
            LabeledContent("Updated", value: build.updatedAt)
            if let exitState = build.exitState {
                LabeledContent("Result", value: exitState.capitalized)
            }
            ForEach(build.diagnostics, id: \.self) { message in
                Label(message, systemImage: "exclamationmark.triangle")
            }
            ForEach(build.screenshots) { artifact in
                BuildScreenshotView(artifact: artifact, load: loadScreenshot)
            }
        } label: {
            HStack {
                VStack(alignment: .leading) {
                    Text(build.projectName).font(.headline)
                    Text(String(build.id.prefix(8))).foregroundStyle(.secondary)
                }
                Spacer()
                if ["queued", "claimed", "running"].contains(build.status) {
                    ProgressView().controlSize(.small)
                }
                Text(build.status.capitalized)
                    .foregroundStyle(build.status == "failed" ? .red : .secondary)
            }
        }
    }
}

private struct BuildScreenshotView: View {
    let artifact: SavedBuildArtifact
    let load: (SavedBuildArtifact) async throws -> Data
    @State private var image: CGImage?
    @State private var unavailable = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(artifact.relativePath, systemImage: "photo")
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 320)
                    .accessibilityLabel(artifact.relativePath)
            } else if unavailable {
                Text("Unavailable")
                    .foregroundStyle(.secondary)
            } else if !artifact.artifactID.isEmpty {
                ProgressView()
            }
        }
        .task(id: artifact.id) {
            guard !artifact.artifactID.isEmpty else {
                unavailable = true
                return
            }
            do {
                let bytes = try await load(artifact)
                guard
                    let source = CGImageSourceCreateWithData(
                        bytes as CFData,
                        [kCGImageSourceShouldCache: false] as CFDictionary
                    ),
                    let thumbnail = CGImageSourceCreateThumbnailAtIndex(
                        source,
                        0,
                        [
                            kCGImageSourceCreateThumbnailFromImageAlways: true,
                            kCGImageSourceCreateThumbnailWithTransform: true,
                            kCGImageSourceThumbnailMaxPixelSize: 2_048,
                            kCGImageSourceShouldCacheImmediately: true,
                        ] as CFDictionary
                    )
                else {
                    unavailable = true
                    return
                }
                image = thumbnail
            } catch {
                unavailable = true
            }
        }
    }
}
