import SparkDesignSystem
import SwiftUI

/// Renders the iPad and Mac Fleet from finished presentation values while FleetModel preserves navigation state.
public struct FleetView: View {
    @Bindable private var model: FleetModel
    private let onAddSpark: () -> Void
    private let onOpen: (String) -> Void
    private let onRemove: (String) -> Void
    private let onCheckAgain: (String) async -> Void
    private let onRetryStorage: () -> Void
    private let onAddDeviceToSeveralSparks: (() -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pendingRemoval: FleetCardPresentation?
    @State private var launchModel: SparkQuickLaunchModel?
    @State private var checkRequest: FleetCheckRequest?

    /// One "check again" tap, identified so the same card can be checked twice in a row.
    private struct FleetCheckRequest: Equatable, Identifiable {
        let id = UUID()
        let entryID: String
    }

    public init(
        model: FleetModel,
        onAddSpark: @escaping () -> Void,
        onOpen: @escaping (String) -> Void,
        onRemove: @escaping (String) -> Void,
        onCheckAgain: @escaping (String) async -> Void,
        onRetryStorage: @escaping () -> Void,
        onAddDeviceToSeveralSparks: (() -> Void)? = nil
    ) {
        self.model = model
        self.onAddSpark = onAddSpark
        self.onOpen = onOpen
        self.onRemove = onRemove
        self.onCheckAgain = onCheckAgain
        self.onRetryStorage = onRetryStorage
        self.onAddDeviceToSeveralSparks = onAddDeviceToSeveralSparks
    }

    /// §51.1: the confirmation names the Spark it removes, not just the action.
    private var removalActionTitle: String {
        String(
            localized: .removeFromThisDevice(
                pendingRemoval?.name ?? String(localized: "this Spark")
            )
        )
    }

    public var body: some View {
        // Derive one presentation per render pass so all cards, tiles and filters share an evaluation instant.
        let presentation = model.presentation
        #if os(macOS)
            let details = model.selectedDetails
        #endif
        let home = model.home
        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let notice = presentation.storageNotice {
                    storageBanner(notice)
                }
                // The Spark cards below carry every per-Spark reading, so this section stays fleet-only.
                FleetDashboardSection(
                    home: home,
                    dashboard: model.dashboard,
                    onOpenSpark: onOpen
                )
                switch presentation.content {
                case .empty:
                    emptyState
                case .filteredEmpty(let totalCount):
                    filterBar(presentation)
                    filteredEmptyState(totalCount: totalCount)
                case .cards(let cards):
                    filterBar(presentation)
                    LazyVStack(spacing: 14) {
                        ForEach(cards) { card in
                            FleetCardView(
                                card: card,
                                live: home.sparks.first { $0.entryID == card.id },
                                isSelected: model.selectedID == card.id,
                                onLaunchModel: {
                                    launchModel = SparkQuickLaunchModel(
                                        library: model.launchLibrary,
                                        targetID: card.id,
                                        launchOnOpen: home.sparks.first { $0.entryID == card.id }?
                                            .action == .launch
                                    )
                                },
                                onConfigureModel: {
                                    launchModel = SparkQuickLaunchModel(
                                        library: model.launchLibrary,
                                        targetID: card.id
                                    )
                                },
                                animatesConnection: FleetMotion.shouldAnimateConnectionPulse(
                                    tone: card.connection.tone,
                                    reduceMotion: reduceMotion
                                ),
                                onSelect: { model.selectedID = card.id },
                                onAction: { perform($0, on: card) }
                            )
                        }
                    }
                }
            }
            .frame(maxWidth: 980, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .navigationTitle("Home")
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
        .sheet(item: $launchModel) { launchModel in
            SparkQuickLaunchView(model: launchModel)
        }
        .refreshable {
            for id in model.targets.map(\.id) { await onCheckAgain(id) }
        }
        .task(id: checkRequest) { await runCheck() }
        .task(id: model.targets.map(\.id)) {
            await runLiveSweep(ids: model.targets.map(\.id))
        }
        .searchable(
            text: $model.query.searchText,
            prompt: String(localized: "Search Sparks")
        )
        .toolbar {
            if let onAddDeviceToSeveralSparks {
                ToolbarItem {
                    Button(action: onAddDeviceToSeveralSparks) {
                        Label("Add Device to Several Sparks", systemImage: "person.2.badge.plus")
                    }
                }
            }
            ToolbarItem {
                Button(action: onAddSpark) {
                    Label("Add Spark", systemImage: "plus")
                }
                .accessibilityLabel("Add a Spark")
                .accessibilityHint("Sets up or pairs another Spark with this device.")
            }
        }
        #if os(macOS)
            .inspector(
                isPresented: Binding(
                    get: { details != nil },
                    set: { if !$0 { model.selectedID = nil } }
                )
            ) {
                FleetDetailsView(details: details)
                .inspectorColumnWidth(min: 260, ideal: 320, max: 420)
            }
        #endif
        .alert(
            String(localized: "Remove this Spark from this device?"),
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            )
        ) {
            Button(removalActionTitle, role: .destructive) {
                if let pendingRemoval {
                    model.forget(pendingRemoval.id)
                    onRemove(pendingRemoval.id)
                }
                pendingRemoval = nil
            }
            Button("Keep", role: .cancel) { pendingRemoval = nil }
        } message: {
            Text(
                """
                This only removes the entry from this device's Fleet. \
                Nothing is changed or deleted on the Spark.
                """
            )
        }
    }

    private func perform(_ action: FleetCardAction, on card: FleetCardPresentation) {
        switch action {
        case .open:
            onOpen(card.id)
        case .checkAgain:
            checkAgain(card.id)
        case .remove:
            pendingRemoval = card
        }
    }

    /// Keep per-target check progress visible until its request finishes or fails.
    private func checkAgain(_ id: String) {
        checkRequest = FleetCheckRequest(entryID: id)
    }

    /// Run the tapped card's check inside the view's own lifetime, never after it is gone.
    private func runCheck() async {
        guard let request = checkRequest else { return }
        model.beginCheck(request.entryID)
        defer { model.endCheck(request.entryID) }
        await onCheckAgain(request.entryID)
    }

    /// Refreshes paired Sparks silently while visible, cancelling on disappearance and restarting when the target set changes.
    private func runLiveSweep(ids: [String]) async {
        while !Task.isCancelled {
            for id in ids where !Task.isCancelled {
                await onCheckAgain(id)
            }
            do {
                try await Task.sleep(for: FleetModel.liveSweepInterval)
            } catch {
                return
            }
        }
    }

    // MARK: Sections

    private func filterBar(_ presentation: FleetPresentation) -> some View {
        let expanded = FleetFilterPresentation.showsExpandedFilters(
            totalCount: presentation.totalCount
        )
        return VStack(alignment: .leading, spacing: 10) {
            // One Spark needs no row of pickers; the filters stay one tap away until the fleet grows.
            if expanded {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { filterControls(presentation) }
                    VStack(alignment: .leading, spacing: 10) { filterControls(presentation) }
                }
            } else {
                Menu {
                    filterControls(presentation)
                } label: {
                    Label("Filter", systemImage: "line.3.horizontal.decrease.circle")
                }
                .fixedSize()
            }
            if expanded || model.query.isFiltering {
                HStack(spacing: 12) {
                    Text(
                        .showingSparks(
                            visible: presentation.visibleCount,
                            total: presentation.totalCount
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    if model.query.isFiltering {
                        Button("Clear Filters", action: model.clearFilters)
                            .buttonStyle(.borderless)
                            .font(.caption)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func filterControls(_ presentation: FleetPresentation) -> some View {
        Picker("Connection", selection: $model.query.connection) {
            ForEach(FleetConnectionFilter.allCases) { Text($0.title).tag($0) }
        }
        Picker("Update state", selection: $model.query.update) {
            ForEach(FleetUpdateFilter.allCases) { Text($0.title).tag($0) }
        }
        Picker("Membership", selection: $model.query.membership) {
            ForEach(FleetMembershipFilter.allCases) { Text($0.title).tag($0) }
        }
        Picker("Installed model", selection: $model.query.installedModel) {
            Text("Any installed model").tag(String?.none)
            ForEach(presentation.installedModelOptions, id: \.self) {
                Text($0).tag(String?.some($0))
            }
        }
        .disabled(presentation.installedModelOptions.isEmpty)
    }

    private var emptyState: some View {
        VStack(spacing: 22) {
            SparkProductArtwork(isConnected: false)
            VStack(spacing: 10) {
                Text(SparkHomeCopy.emptyTitle)
                    .font(.largeTitle.bold())
                Text("Connect your Spark for help with questions, plans and everyday tasks.")
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
            }
            Button(action: onAddSpark) {
                Label("Add Spark", systemImage: "plus")
                    .font(.title3.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityLabel("Add a Spark")
            .accessibilityHint("Opens setup or pairing for another Spark.")
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    private func filteredEmptyState(totalCount: Int) -> some View {
        ContentUnavailableView {
            Label("No Sparks match", systemImage: "line.3.horizontal.decrease.circle")
        } description: {
            Text(
                .noSparksMatch(totalCount)
            )
        } actions: {
            Button("Clear Filters", action: model.clearFilters)
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, minHeight: 240)
    }

    private func storageBanner(_ notice: FleetStorageNotice) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(notice.title, systemImage: "externaldrive.badge.exclamationmark")
                .font(.headline)
                .foregroundStyle(.orange)
            Text(notice.message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button(notice.actionTitle, action: onRetryStorage)
                .buttonStyle(.bordered)
                .accessibilityLabel(notice.actionAccessibilityLabel)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .contain)
    }
}
