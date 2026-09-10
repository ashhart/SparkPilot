import Observation
import SparkLibrary
import SwiftUI

/// Select the automation's host independently of whichever dashboard was last opened.
@MainActor
@Observable
final class SparkAutomationSelection {
    let library: SparkLibrary
    private let openModel: (String) async throws -> SparkAutomationsModel
    private var generation = 0
    private(set) var openingID: String?
    private(set) var errorMessage: String?
    private(set) var model: SparkAutomationsModel?
    private(set) var createsAutomation = false
    var destinationID: String?

    init(library: SparkLibrary, openModel: @escaping (String) async throws -> SparkAutomationsModel)
    {
        self.library = library
        self.openModel = openModel
    }

    var entries: [LibraryEntry] {
        library.entries.filter { $0.externalClusterRegistration == nil }.sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    func cancel() {
        generation += 1
        openingID = nil
        errorMessage = nil
    }

    func open(_ id: String, create: Bool) async {
        cancel()
        let request = generation
        model = nil
        destinationID = nil
        guard entries.contains(where: { $0.id == id }) else { return }
        openingID = id
        defer { if generation == request { openingID = nil } }
        do {
            let opened = try await openModel(id)
            guard generation == request, !Task.isCancelled,
                library.entry(id: id) != nil
            else { return }
            guard opened.targetID == id else {
                throw SelectionFailure(
                    message: String(localized: "The selected Spark changed. Choose it again.")
                )
            }
            guard !create || opened.canManage else {
                throw SelectionFailure(
                    message: String(
                        localized:
                            "Only an owner or administrator can add automations on this Spark."
                    )
                )
            }
            model = opened
            createsAutomation = create
            destinationID = id
        } catch {
            guard generation == request, !Task.isCancelled else { return }
            errorMessage =
                (error as? SelectionFailure)?.message
                ?? String(
                    localized:
                        "Could not connect to this Spark. Check its connection and try again."
                )
        }
    }

    struct SelectionFailure: Error { let message: String }
}

struct SparkAutomationsLibraryView: View {
    @State private var selection: SparkAutomationSelection
    @State private var choosingSpark = false
    @State private var pendingDestination: String?
    private let onAddSpark: () -> Void

    init(onboarding: RetailOnboardingModel, onAddSpark: @escaping () -> Void) {
        self.onAddSpark = onAddSpark
        _selection = State(
            initialValue: SparkAutomationSelection(library: onboarding.library) { id in
                #if DEBUG
                    if FleetSampleFleet.requested() != nil,
                        let entry = onboarding.library.entry(id: id),
                        let route = entry.connectRoute?.baseURL
                    {
                        return FamilyPreviewWebAccess.model(route: route, targetID: id)
                    }
                #endif
                // Reuse Home's signed identity checks and LAN/Tailscale route recovery without navigating to Home.
                await onboarding.openLibraryEntry(id)?.value
                await onboarding.deviceManagementModel?.loadIfNeeded()
                if let failure = onboarding.libraryOpenFailure, failure.entryID == id {
                    throw SparkAutomationSelection.SelectionFailure(message: failure.reason.message)
                }
                guard let model = onboarding.automationsModel, model.targetID == id else {
                    throw SparkAutomationSelection.SelectionFailure(
                        message: String(
                            localized:
                                "This Spark could not open automations. Check its connection and try again."
                        )
                    )
                }
                return model
            }
        )
    }

    var body: some View {
        List {
            Section {
                Text(
                    "Choose the Spark that will run your automations, even when this device is asleep."
                )
                .foregroundStyle(.secondary)
                #if DEBUG
                    if FleetSampleFleet.requested() != nil {
                        Text("Preview · sample automations · nothing runs on a Spark")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                #endif
            }
            if selection.entries.isEmpty {
                ContentUnavailableView {
                    Label("Add a Spark first", systemImage: "desktopcomputer")
                } description: {
                    Text("Pair a Spark to give your automations a place to run.")
                } actions: {
                    Button("Add Spark", action: onAddSpark).buttonStyle(.borderedProminent)
                }
            } else {
                Section("Your Sparks") {
                    ForEach(selection.entries) { entry in
                        sparkRow(entry, create: false)
                    }
                }
            }
            if !choosingSpark { errorSection }
        }
        .navigationTitle("Automations")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Add automation", systemImage: "plus") { choosingSpark = true }
                    .disabled(selection.entries.isEmpty)
                    .accessibilityIdentifier("spark.automations.add")
            }
        }
        .sheet(
            isPresented: $choosingSpark,
            onDismiss: {
                selection.cancel()
                selection.destinationID = pendingDestination
                pendingDestination = nil
            }
        ) {
            NavigationStack {
                List {
                    Section {
                        ForEach(selection.entries) { entry in sparkRow(entry, create: true) }
                    } footer: {
                        Text("This Spark keeps the automation and runs it on schedule.")
                    }
                    errorSection
                }
                .navigationTitle("Choose a Spark")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            selection.cancel()
                            choosingSpark = false
                        }
                    }
                }
            }
        }
        .navigationDestination(item: $selection.destinationID) { id in
            if let model = selection.model, model.targetID == id,
                let entry = selection.library.entry(id: id)
            {
                SparkAutomationsView(
                    model: model,
                    sparkName: entry.displayName,
                    createOnOpen: selection.createsAutomation
                )
            }
        }
        .onChange(of: selection.library.entries) { _, _ in
            if let id = selection.destinationID, selection.library.entry(id: id) == nil {
                selection.cancel()
                selection.destinationID = nil
            }
        }
    }

    private func sparkRow(_ entry: LibraryEntry, create: Bool) -> some View {
        Button {
            Task {
                await selection.open(entry.id, create: create)
                if create, let id = selection.destinationID {
                    pendingDestination = id
                    selection.destinationID = nil
                    choosingSpark = false
                }
            }
        } label: {
            HStack {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.displayName).foregroundStyle(.primary)
                        Text(create ? "Run the automation here" : "View automations")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "desktopcomputer")
                }
                Spacer()
                if selection.openingID == entry.id {
                    ProgressView()
                } else {
                    Image(systemName: "chevron.right").foregroundStyle(.secondary)
                }
            }
        }
        .disabled(selection.openingID != nil)
        .accessibilityIdentifier("spark.automations.\(create ? "pick" : "target").\(entry.id)")
    }

    @ViewBuilder private var errorSection: some View {
        if let error = selection.errorMessage {
            Section {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text("Select a Spark above to try again.").font(.footnote)
            }
        }
    }
}
