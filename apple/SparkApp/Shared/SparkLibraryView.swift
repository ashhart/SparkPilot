import SparkDesignSystem
import SparkLibrary
import SwiftUI

enum SparkHomeCopy {
    static let navigationTitle = String(localized: "Home")
    static let emptyTitle = String(localized: "Welcome to your DGX Spark")
}

/// Lists local cards keyed by namespaced identity, with removal available regardless of connectivity or cluster role.
struct SparkLibraryView: View {
    let library: SparkLibrary
    let onAddSpark: () -> Void
    let onOpen: (String) -> Void
    let onRemove: (String) -> Void
    let onRetryStorage: () -> Void
    /// What Home decided to show for each Spark; empty until the fleet model supplies it.
    var home: FleetHomePresentation = .empty
    /// Render supplemental library content inside the existing scroll view above its cards.
    var header: AnyView? = nil
    var onAddDeviceToSeveralSparks: (() -> Void)? = nil
    /// Pull to refresh re-probes every saved Spark; absent only where no owner model can do that.
    var onRefresh: (@MainActor () async -> Void)? = nil

    @State private var pendingRemoval: LibraryEntry?
    @State private var launchModel: SparkQuickLaunchModel?

    /// §51.1: the confirmation names the Spark it removes, not just the action.
    private var removalActionTitle: String {
        String(
            localized: .removeFromThisDevice(
                pendingRemoval?.name ?? String(localized: "this Spark")
            )
        )
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                if library.storageStatus.isSessionOnly {
                    storageBanner
                }
                if let header {
                    header
                }

                if library.entries.isEmpty {
                    emptyState
                        .padding(.top, 40)
                } else {
                    VStack(spacing: 16) {
                        ForEach(library.entries) { entry in
                            card(for: entry)
                        }
                    }

                    Button(action: onAddSpark) {
                        Label("Add Spark", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }
            .frame(maxWidth: 620)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .refreshable {
            if let onRefresh { await onRefresh() }
        }
        .sheet(item: $launchModel) { model in
            SparkQuickLaunchView(model: model)
        }
        .navigationTitle(SparkHomeCopy.navigationTitle)
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
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
            }
        }
        .alert(
            "Remove this Spark from this device?",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            )
        ) {
            Button(removalActionTitle, role: .destructive) {
                if let pendingRemoval {
                    onRemove(pendingRemoval.id)
                }
                pendingRemoval = nil
            }
            Button("Keep", role: .cancel) {
                pendingRemoval = nil
            }
        } message: {
            Text(
                """
                This only removes the entry from this device's library. \
                Nothing is changed or deleted on the Spark.
                """
            )
        }
    }

    /// Prefer the live card, which carries this Spark's own readings and its one model action.
    @ViewBuilder
    private func card(for entry: LibraryEntry) -> some View {
        if let live = home.sparks.first(where: { $0.entryID == entry.id }) {
            FleetHomeCardView(
                card: live,
                onOpen: { onOpen(entry.id) },
                onModelAction: {
                    launchModel = SparkQuickLaunchModel(
                        library: library,
                        targetID: entry.id,
                        launchOnOpen: live.action == .launch
                    )
                },
                onConfigureModel: {
                    launchModel = SparkQuickLaunchModel(library: library, targetID: entry.id)
                },
                canOpen: entry.canOpen,
                openHint: LibraryCardOpenHint.text(for: entry)
            ) {
                LibraryCardMenu(entry: entry, onRemove: { pendingRemoval = entry })
            }
            .padding(16)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 16))
        } else if entry.kind == .cluster {
            ClusterLibraryCard(
                entry: entry,
                onOpen: { onOpen(entry.id) },
                onRemove: { pendingRemoval = entry }
            )
        } else {
            StandaloneLibraryCard(
                entry: entry,
                onOpen: { onOpen(entry.id) },
                onRemove: { pendingRemoval = entry }
            )
        }
    }

    private var storageBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "externaldrive.badge.exclamationmark")
                    .foregroundStyle(.orange)
                Text("Your Sparks aren't being saved")
                    .font(.headline)
            }
            Text(
                """
                Nothing is lost yet — this device could not open its Spark library \
                storage, so changes won't survive relaunching the app. Try restoring \
                storage before you add Sparks.
                """
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)

            Button("Try Again", action: onRetryStorage)
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .contain)
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
        }
    }
}

/// Says why a card cannot be opened, so a disabled tap is never a mystery.
enum LibraryCardOpenHint {
    static func text(for entry: LibraryEntry) -> String {
        if entry.canOpen {
            return String(
                localized:
                    "Connects to this Spark on your network, or over Tailscale when you are away."
            )
        }
        if entry.externalClusterRegistration != nil {
            return String(
                localized:
                    "This read-only cluster keeps member recovery routes. Remove the grouping to open each Spark separately."
            )
        }
        return String(localized: "No reachable route yet. Remove the entry to clear it.")
    }
}

/// Keeps removal available in every connection state, as a menu or as a direct button after an identity change.
struct LibraryCardMenu: View {
    let entry: LibraryEntry
    let onRemove: () -> Void

    var body: some View {
        if entry.issue == .identityMismatch {
            Button(action: onRemove) {
                Label("Remove", systemImage: "trash")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Remove entry")
            .help(String(localized: "Remove this entry from this device"))
        } else {
            Menu {
                Button("Remove Entry…", role: .destructive, action: onRemove)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .accessibilityLabel("More actions")
            }
            .menuStyle(.borderlessButton)
        }
    }
}

/// Disables opening only when no route exists while keeping the Remove Entry menu available in every connection state.
private struct LibraryCardActions<Content: View>: View {
    let entry: LibraryEntry
    let content: Content
    let onOpen: () -> Void
    let onRemove: () -> Void

    init(
        entry: LibraryEntry,
        onOpen: @escaping () -> Void,
        onRemove: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.entry = entry
        self.content = content()
        self.onOpen = onOpen
        self.onRemove = onRemove
    }

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onOpen) {
                content
            }
            .buttonStyle(.plain)
            .disabled(!entry.canOpen)
            .accessibilityHint(LibraryCardOpenHint.text(for: entry))
            LibraryCardMenu(entry: entry, onRemove: onRemove)
        }
        .padding(16)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .contain)
    }
}

/// A standalone Spark card. Identity is the node_id; routes merge in place.
private struct StandaloneLibraryCard: View {
    let entry: LibraryEntry
    let onOpen: () -> Void
    let onRemove: () -> Void

    private var presentation: LibraryConnectionPresentation {
        LibraryConnectionPresentation.resolve(entry)
    }

    var body: some View {
        LibraryCardActions(entry: entry, onOpen: onOpen, onRemove: onRemove) {
            HStack(spacing: 12) {
                SparkProductMark(size: 44)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(entry.displayName)
                            .font(.headline)
                        if entry.issue == .identityMismatch {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .accessibilityLabel("Identity changed")
                        }
                    }
                    HStack(spacing: 6) {
                        Label(presentation.label, systemImage: presentation.symbol)
                            .font(.subheadline)
                            .foregroundStyle(presentation.isOnline ? Color.green : .secondary)
                        if presentation.isOnline {
                            // §41.6: the security state stays visible beside the route.
                            Image(systemName: "lock.fill")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .accessibilityLabel("Pinned identity verified")
                        }
                    }
                    if let path = presentation.path {
                        SparkConnectionPathBadge(path: path)
                            .font(.caption)
                    }
                    if let summary = LibraryCardSummary.resolve(entry: entry) {
                        Text(verbatim: summary.lastContact)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(verbatim: summary.activeModel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(
                            verbatim: [summary.availableMemory, summary.installedModels]
                                .joined(separator: " · ")
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                Text(verbatim: LibraryCardSummary.action(for: entry).title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Represent a logical cluster as one target with physical members available for maintenance and recovery (§10.8.7).
private struct ClusterLibraryCard: View {
    let entry: LibraryEntry
    let onOpen: () -> Void
    let onRemove: () -> Void

    private var presentation: LibraryConnectionPresentation {
        LibraryConnectionPresentation.resolve(entry)
    }

    var body: some View {
        LibraryCardActions(entry: entry, onOpen: onOpen, onRemove: onRemove) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "square.stack.3d.up.fill")
                        .font(.title2)
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 34)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.displayName)
                            .font(.headline)
                        Label(presentation.label, systemImage: presentation.symbol)
                            .font(.subheadline)
                            .foregroundStyle(presentation.isOnline ? Color.green : .secondary)
                        if let path = presentation.path {
                            SparkConnectionPathBadge(path: path)
                                .font(.caption)
                        }
                    }
                    Spacer(minLength: 0)
                }

                if !entry.members.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(entry.members) { member in
                            HStack(spacing: 6) {
                                Image(
                                    systemName: member.role == .leader
                                        ? "star.circle.fill" : "circle"
                                )
                                .foregroundStyle(
                                    member.role == .leader ? Color.yellow : Color.secondary
                                )
                                Text(member.name)
                                Spacer()
                                Text(
                                    entry.externalClusterRegistration != nil
                                        ? String(localized: "Member")
                                        : member.role == .leader
                                            ? String(localized: "Coordinator")
                                            : String(localized: "Worker")
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                            .font(.subheadline)
                        }
                    }
                    .padding(10)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
