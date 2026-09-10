import SparkDesignSystem
import SwiftUI

/// Make card selection and individual actions reachable by keyboard and VoiceOver.
struct FleetCardView: View {
    let card: FleetCardPresentation
    /// The Spark's own live readings, when Home has them.
    let live: FleetHomeSparkCard?
    let isSelected: Bool
    let onLaunchModel: () -> Void
    var onConfigureModel: (() -> Void)? = nil
    let animatesConnection: Bool
    let onSelect: () -> Void
    let onAction: (FleetCardAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            identityButton

            measurements
                .accessibilitySortPriority(FleetFocusOrder.priority(for: .activity))
            modelAction
                .accessibilitySortPriority(FleetFocusOrder.priority(for: .activity))

            if !card.members.isEmpty {
                memberList
                    .accessibilitySortPriority(FleetFocusOrder.priority(for: .activity))
            }

            ForEach(card.blockers, id: \.self) { blocker in
                Label(blocker, systemImage: "exclamationmark.octagon.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            ForEach(card.warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            if let evidenceNote = card.evidenceNote {
                Text(evidenceNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            actionRow
                .accessibilitySortPriority(FleetFocusOrder.priority(for: .actions))
        }
        .padding(16)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Color.accentColor, lineWidth: isSelected ? 2 : 0)
        )
        .contentShape(RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(card.accessibilityLabel)
    }

    private var identityButton: some View {
        Button {
            onAction(.open)
        } label: {
            HStack(alignment: .top, spacing: 14) {
                artwork
                VStack(alignment: .leading, spacing: 6) {
                    Text(card.name)
                        .font(.title3.weight(.semibold))
                        .accessibilitySortPriority(FleetFocusOrder.priority(for: .name))
                    connectionRow
                        .accessibilitySortPriority(FleetFocusOrder.priority(for: .connection))
                    FleetConnectionPathRow(connection: card.connection)
                        .accessibilitySortPriority(FleetFocusOrder.priority(for: .connection))
                    Text(card.membership)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilitySortPriority(FleetFocusOrder.priority(for: .connection))
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!card.actions.contains(.open))
        .accessibilityIdentifier("spark.fleet.open.\(card.id)")
        .accessibilityHint("Opens this Spark")
    }

    @ViewBuilder
    private var artwork: some View {
        switch card.artwork {
        case .spark:
            SparkProductMark(size: 48)
        case .cluster(let memberCount):
            SparkProductMark(size: 48)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "square.stack.3d.up.fill")
                        .font(.footnote)
                        .foregroundStyle(Color.accentColor)
                        .padding(3)
                        .background(.background, in: Circle())
                        .accessibilityHidden(true)
                }
                .accessibilityLabel(Text(.clusterOfSparks(memberCount)))
        }
    }

    private var connectionRow: some View {
        HStack(spacing: 8) {
            // Keep the state label under Reduced Motion because the pulse conveys no additional information.
            Label(card.connection.label, systemImage: card.connection.symbol)
                .font(.subheadline)
                .foregroundStyle(tint)
                .symbolEffect(.pulse, isActive: animatesConnection)
                .accessibilityLabel(Text(.connectionStatic(card.connection.label)))
            Text(.lastContact(card.lastContact))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if card.connection.isChecking {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Checking this Spark")
            }
        }
    }

    private var measurements: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 18) { measurementItems }
            VStack(alignment: .leading, spacing: 8) { measurementItems }
        }
    }

    @ViewBuilder
    private var measurementItems: some View {
        if let live {
            ForEach(live.metrics) { metric in
                measurement(title: metric.title, value: metric.value, symbol: metric.symbol)
            }
        } else {
            measurement(
                title: String(localized: "Unified memory"),
                value: card.availableMemory,
                symbol: "memorychip"
            )
            measurement(
                title: String(localized: "Active model"),
                value: card.activeModel,
                symbol: "play.circle"
            )
        }
        measurement(
            title: String(localized: "Installed"),
            value: card.installedModels,
            symbol: "square.stack.3d.up"
        )
    }

    /// One model action, matching the dashboard header and the iPhone card.
    @ViewBuilder
    private var modelAction: some View {
        switch live?.action {
        case .loading(let line, let fraction):
            VStack(alignment: .leading, spacing: 8) {
                Label(line, systemImage: "hourglass")
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if let fraction { ProgressView(value: fraction) }
            }
            .accessibilityElement(children: .combine)
        case .launch:
            launchButton.buttonStyle(.borderedProminent)
            if let onConfigureModel {
                Button("Change preset", action: onConfigureModel).buttonStyle(.bordered)
            }
        case .switchModel:
            launchButton.buttonStyle(.bordered)
        case .none, .some(.none):
            EmptyView()
        }
    }

    private var launchButton: some View {
        Button(action: onLaunchModel) {
            Label(
                live?.action.title ?? "",
                systemImage: live?.action.symbol ?? "play.fill"
            )
            .font(.subheadline.weight(.semibold))
            .frame(minHeight: 44)
        }
    }

    private func measurement(title: String, value: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(title, systemImage: symbol)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.medium))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var memberList: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(card.members) { member in
                HStack(spacing: 8) {
                    Text(member.name)
                    Text(member.role)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Text(member.reachability)
                        .foregroundStyle(member.tone == .positive ? Color.secondary : Color.orange)
                }
                .font(.caption)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    private var actionRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                cardActionButtons
                Spacer(minLength: 0)
                #if os(macOS)
                    detailsButton
                #endif
            }
            VStack(alignment: .leading, spacing: 10) {
                cardActionButtons
                #if os(macOS)
                    detailsButton
                #endif
            }
        }
    }

    @ViewBuilder
    private var cardActionButtons: some View {
        ForEach(card.actions) { action in
            if action == .open {
                Button {
                    onAction(action)
                } label: {
                    Label(action.title, systemImage: action.symbol)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityLabel(action.accessibilityLabel(for: card.name))
            } else {
                Button(role: action.isDestructive ? .destructive : nil) {
                    onAction(action)
                } label: {
                    Label(action.title, systemImage: action.symbol)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel(action.accessibilityLabel(for: card.name))
            }
        }
    }

    private var detailsButton: some View {
        Button("Details", systemImage: "info.circle", action: onSelect)
            .buttonStyle(.bordered)
            .accessibilityLabel(Text(.showDetailsFor(card.name)))
            .accessibilityHint("Shows identity, routes, members, and operation evidence.")
    }

    private var tint: Color {
        switch card.connection.tone {
        case .positive: .green
        case .neutral: .secondary
        case .caution: .orange
        case .critical: .red
        }
    }
}

/// Present identity, route, membership, notice and operation details in the fleet inspector.
struct FleetDetailsView: View {
    let details: FleetDetailsPresentation?

    var body: some View {
        Group {
            if let details {
                List {
                    ForEach(details.sections) { section in
                        Section(section.title) {
                            ForEach(section.rows) { row in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(row.label)
                                        .font(.subheadline)
                                    Text(row.value)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                                .accessibilityElement(children: .combine)
                            }
                        }
                    }
                }
                .navigationTitle(details.title)
            } else {
                ContentUnavailableView(
                    String(localized: "No Spark selected"),
                    systemImage: "info.circle",
                    description: Text("Choose Details on a card to inspect its evidence.")
                )
            }
        }
    }
}
