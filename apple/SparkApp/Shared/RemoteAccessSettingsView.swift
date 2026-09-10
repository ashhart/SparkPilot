import SparkAPI
import SparkDesignSystem
import SwiftUI

/// Universal Settings pane for the selected Spark's optional remote route: one tap to turn it on.
public struct RemoteAccessSettingsView: View {
    @Bindable private var model: RemoteAccessModel
    @Environment(\.scenePhase) private var scenePhase

    public init(model: RemoteAccessModel) {
        self.model = model
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 8) {
                    Text(String(localized: "Remote access"))
                        .font(.title2.bold())
                    SparkTooltipButton(
                        title: String(localized: "Remote access"),
                        message:
                            String(
                                localized:
                                    "Lets SparkPilot reach this Spark when this device is away from the Spark's network, over Tailscale."
                            )
                    )
                }

                if model.status?.enabled == false, !model.isShowingCachedStatus {
                    turnOnCard
                }
                SparkTailscaleSettingsView(model: model)

                if model.status?.enabled == true && model.status?.mode == .privateOverlay {
                    privateRouteCard
                }

                if let cardState = model.cardState {
                    RemoteAccessCard(state: cardState) {
                        Task { await model.prepareDisable() }
                    }
                } else if model.isRefreshing {
                    SparkSkeletonList(
                        rowCount: 1,
                        accessibilityLabel: String(localized: "Loading remote access status")
                    )
                } else {
                    // A failed read is not evidence that remote access is off.
                    Label(
                        """
                        SparkPilot could not read this Spark's remote access setting, \
                        so it cannot say whether it is on or off.
                        """,
                        systemImage: "questionmark.circle"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        .quaternary.opacity(0.45),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                    )
                }

                if model.isShowingCachedStatus {
                    Label("Last known status", systemImage: "clock.arrow.circlepath")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if model.isRemoteRouteUnhealthy {
                    unhealthyNotice
                }
                if model.isRefreshing || model.isDisabling {
                    ProgressView()
                }
                if let errorMessage = model.errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                if let operation = model.lastOperation {
                    Text(
                        .remoteOperation(
                            id: operation.id.uuidString,
                            state: operation.state.rawValue
                        )
                    )
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: 560)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Remote Access")
        .task(id: scenePhase) {
            if scenePhase == .active {
                await model.loadIfNeeded(refreshIfLoaded: true)
            } else {
                model.invalidatePrivateRouteVerification()
            }
        }
        .refreshable { await model.refresh() }
        // Provide a macOS refresh button because refreshable does not trigger there.
        .toolbar {
            ToolbarItem {
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await model.refresh() }
                }
                .disabled(model.isWorking)
            }
        }
        .alert(
            model.disableConfirmationTitle,
            isPresented: Binding(
                get: { model.isConfirmingDisable },
                set: { presented in
                    if !presented { model.cancelDisableConfirmation() }
                }
            )
        ) {
            Button(model.disableActionTitle, role: .destructive) {
                Task { await model.confirmDisable() }
            }
            Button("Cancel", role: .cancel) {
                model.cancelDisableConfirmation()
            }
        } message: {
            Text(model.reviewMessage)
        }
    }

    /// Explanation, one button, and whatever the enable currently needs from the owner.
    private var turnOnCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Reach this Spark from anywhere", systemImage: "lock.shield")
                .font(.headline)
            RemoteAccessExplanationView()
            NavigationLink {
                RemoteAccessSetupGuideView(model: model)
            } label: {
                Label("Set up step by step", systemImage: "list.number")
            }
            .buttonStyle(.bordered)
            RemoteAccessEnableControls(model: model)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    /// Remote access is on: name the route, say whether this device has verified it, and offer a check.
    private var privateRouteCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let hostname = model.status?.hostname {
                Label(
                    String(localized: .tailscaleReachableAs(hostname)),
                    systemImage: "lock.shield.fill"
                )
                .font(.headline)
            }
            if case .failed(let action) = model.turnOnPhase {
                RemoteAccessNextActionCard(
                    action: action,
                    tryAgain: { model.dismissTurnOnOutcome() },
                    checkAgain: {
                        model.dismissTurnOnOutcome()
                        Task { await model.recheckRemoteHealth() }
                    },
                    dismiss: { model.dismissTurnOnOutcome() }
                )
            }
            TailscaleConnectionStatusView(model: model)
            TailscaleOpenAppButton(beforeOpening: model.invalidatePrivateRouteVerification)
            Button("Check Private Connection") {
                Task { await model.recheckRemoteHealth() }
            }
            .buttonStyle(.bordered)
            .disabled(model.isWorking)
            Text(
                "To test it away from home, use mobile data or another Wi-Fi network, open this Spark and send a chat. The Home card says which path is in use."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
            if let hostname = model.status?.hostname,
                let address = SparkAPIAddress.overlay(hostname: hostname, basedOn: model.route)
            {
                developerAddress(address)
            }
            NavigationLink("Account and connection help") {
                RemoteAccessSetupGuideView(model: model)
            }
            RemoteAccessExplanationView()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    /// The Spark's own API address over Tailscale, for anyone who set a tool up with the local one.
    private func developerAddress(_ address: SparkAPIAddress) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Developer tools").font(.subheadline.weight(.semibold))
            Text(
                "Over Tailscale the Spark's own API address is its Tailscale name, not the .local name:"
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
            HStack(spacing: 4) {
                Text(address.baseURLText)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
                SparkChatCopyButton(
                    content: address.baseURLText,
                    label: String(localized: "Copy Spark API base URL")
                )
            }
            Text(SparkAPIAddress.harnessNote)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(SparkAPIAddress.bridgeNote)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var unhealthyNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                String(
                    localized:
                        "The remote route is unhealthy. Use the local network, check Tailscale on the Spark, then check again or stop using the route."
                ),
                systemImage: "wrench.and.screwdriver"
            )
            .font(.callout)
            .foregroundStyle(.orange)
            Button("Check Again") {
                Task { await model.recheckRemoteHealth() }
            }
            .buttonStyle(.bordered)
            .disabled(model.isWorking)
        }
    }

}
