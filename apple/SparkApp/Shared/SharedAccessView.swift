import Foundation
import Observation
import SparkAPI
import SparkDesignSystem
import SwiftUI

/// The owner's Shared access screen: who is using this Spark, under what limits, and what they used.
public struct SharedAccessView: View {
    @Bindable var model: SharedAccessModel
    let onInvite: () -> Void

    public init(model: SharedAccessModel, onInvite: @escaping () -> Void) {
        self.model = model
        self.onInvite = onInvite
    }

    public var body: some View {
        List {
            if let errorMessage = model.errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
            if model.rows.isEmpty {
                Section {
                    ContentUnavailableView {
                        Label("Nobody else uses this Spark", systemImage: "person.2")
                    } description: {
                        Text(
                            "Share it with a friend or someone at home. You choose which models, when, and how much."
                        )
                    } actions: {
                        Button(String(localized: "Share your Spark"), action: onInvite)
                    }
                }
            }
            ForEach(model.rows) { row in
                Section {
                    SharedAccessGuestCard(row: row, model: model)
                }
            }
        }
        .navigationTitle(Text("Shared access"))
        .refreshable { await model.refresh() }
        .task { await model.loadIfNeeded() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: onInvite) {
                    Label("Share your Spark", systemImage: "person.badge.plus")
                }
                .accessibilityIdentifier("shared.access.invite")
            }
        }
        .alert(
            Text("Stop sharing?"),
            isPresented: Binding(
                get: { model.revocationConfirmation != nil },
                set: { if !$0 { model.revocationConfirmation = nil } }
            )
        ) {
            if let row = model.revocationConfirmation {
                Button(String(localized: "Stop sharing"), role: .destructive) {
                    Task { await model.revoke(row) }
                }
            }
            Button(String(localized: "Keep sharing"), role: .cancel) {
                model.revocationConfirmation = nil
            }
        } message: {
            Text("They lose access at once, and the Spark records that you stopped it.")
        }
    }
}

/// One guest: their state, their limits and what they used today and this week.
struct SharedAccessGuestCard: View {
    let row: SharedAccessGuestRow
    @Bindable var model: SharedAccessModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(row.name).font(.headline)
                Spacer()
                Text(stateLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(stateColour)
            }
            Text(.sharedAccessModelCount(row.guest.allowedModels.count))
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(row.hoursLabel)
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(.sharedAccessBudgetToday(row.usedToday, row.budget))
                .font(.callout)
            ProgressView(
                value: Double(min(row.usedToday, row.budget)),
                total: Double(max(row.budget, 1))
            )
            .accessibilityLabel(Text(.sharedAccessBudgetToday(row.usedToday, row.budget)))
            Text(.sharedAccessRequestsToday(row.requestsToday))
                .font(.caption)
                .foregroundStyle(.secondary)
            if row.refusalsThisWeek > 0 {
                Text(.sharedAccessRefusalCount(row.refusalsThisWeek))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(row.topRefusals, id: \.reason) { refusal in
                    Text(SharedAccessRefusal.label(refusal.reason))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if let lastSeen = row.guest.lastSeenAt {
                Text(.sharedAccessLastSeen(DeviceGrantPresentation.timestampLabel(lastSeen)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            controls
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var controls: some View {
        if row.hasJoined {
            HStack(spacing: 16) {
                switch row.state {
                case .pending:
                    Button(String(localized: "Confirm")) { Task { await model.confirm(row) } }
                        .accessibilityIdentifier("shared.access.confirm")
                case .active:
                    Button(String(localized: "Pause")) { Task { await model.pause(row) } }
                case .paused:
                    Button(String(localized: "Resume")) { Task { await model.resume(row) } }
                case .revoked:
                    EmptyView()
                }
                if row.state != .revoked {
                    Button(String(localized: "Stop sharing"), role: .destructive) {
                        model.revocationConfirmation = row
                    }
                }
                if model.busyDeviceID == row.id {
                    ProgressView()
                }
            }
            .buttonStyle(.bordered)
            .font(.callout)
        } else {
            Text("Waiting for them to open the link you sent.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var stateLabel: String {
        switch row.state {
        case .pending:
            return row.hasJoined
                ? String(localized: "Waiting for you") : String(localized: "Invited")
        case .active: return String(localized: "Active")
        case .paused: return String(localized: "Paused")
        case .revoked: return String(localized: "Stopped")
        }
    }

    private var stateColour: Color {
        switch row.state {
        case .pending: .orange
        case .active: .green
        case .paused: .secondary
        case .revoked: .secondary
        }
    }
}

/// Turn a refusal code into something the owner can act on.
enum SharedAccessRefusal {
    static func label(_ code: String) -> String {
        switch code {
        case "GUEST_MODEL_NOT_ALLOWED":
            String(localized: "Asked for a model you have not shared")
        case "GUEST_OUTSIDE_HOURS":
            String(localized: "Tried outside the hours you set")
        case "GUEST_BUDGET_EXHAUSTED":
            String(localized: "Ran out of the daily budget")
        case "GUEST_CONCURRENCY_LIMIT":
            String(localized: "Asked for more at once than you allow")
        case "GUEST_AWAITING_OWNER":
            String(localized: "Tried before you confirmed them")
        case "GUEST_ACCESS_PAUSED":
            String(localized: "Tried while paused")
        case "GUEST_ACCESS_EXPIRED":
            String(localized: "Tried after their access ran out")
        default:
            String(localized: "Refused by your limits")
        }
    }
}
