import Foundation
import SwiftUI

enum RemoteAccessSetupLinks {
    static let account = URL(string: "https://login.tailscale.com/start")!
    static let devices = URL(string: "https://login.tailscale.com/admin/machines")!
    static let plans = URL(string: "https://tailscale.com/pricing")!
    static let sharing = URL(string: "https://tailscale.com/kb/1084/sharing")!
    static var download: URL {
        #if os(macOS)
            URL(string: "https://tailscale.com/download/mac")!
        #else
            URL(string: "https://tailscale.com/download/ios")!
        #endif
    }
}

struct RemoteAccessSetupGuideView: View {
    @Bindable var model: RemoteAccessModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        List {
            Section("Why use Tailscale?") {
                Text(RemoteAccessExplanation.thirdPartyNotice)
                Text(
                    "Use your Spark at home from mobile data, another Wi-Fi network or while travelling; Tailscale creates an encrypted connection between your devices."
                )
                Text(
                    "Tailscale is optional; on your home network, SparkPilot can connect directly."
                )
                Text("Start while you are on the same network as your Spark.")
                    .foregroundStyle(.secondary)
            }
            if model.status?.enabled == true {
                Section("Your connection") { TailscaleConnectionStatusView(model: model) }
            }
            Section("1. Create or use an account") {
                Text(
                    "Tailscale offers a free Personal plan for connecting your devices; check its current limits when you sign up."
                )
                Text(
                    "Choose Apple, Google or another supported sign-in on Tailscale’s website; if you already have an account, use that same sign-in throughout setup."
                )
                Link("Create or sign in to Tailscale", destination: RemoteAccessSetupLinks.account)
                Link("Check Tailscale plans", destination: RemoteAccessSetupLinks.plans)
                Text(
                    "Tailscale handles sign-in in your browser; SparkPilot does not ask for your account password."
                )
                .font(.footnote).foregroundStyle(.secondary)
                Text("When you finish, come back to SparkPilot to continue with step 2.")
            }
            Section("2. Connect this device") {
                TailscaleOpenAppButton(beforeOpening: model.invalidatePrivateRouteVerification)
                Text(
                    "Open Tailscale, sign in with the account from step 1, and allow its VPN connection when this device asks; leave Tailscale connected, then return to SparkPilot."
                )
                Text(
                    "Installing the app alone does not connect it; check that Tailscale says Connected."
                )
                .font(.footnote).foregroundStyle(.secondary)
            }
            Section("3. Connect your Spark") {
                if model.status?.enabled == true, model.status?.mode == .privateOverlay,
                    !model.isShowingCachedStatus
                {
                    Label("Remote access is enabled on the Spark", systemImage: "checkmark.circle")
                } else {
                    Text(
                        "SparkPilot prepares Tailscale on the Spark, then shows a sign-in link; open it and use the same account from step 1 to approve your Spark."
                    )
                    RemoteAccessEnableControls(model: model)
                }
                if let error = model.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
            }
            Section("4. Check it works") {
                Button("Check private connection") { Task { await model.recheckRemoteHealth() } }
                    .disabled(
                        model.status?.enabled != true || model.isRefreshing || model.isDisabling
                            || model.isEnabling
                    )
                if !model.isPrivateRouteVerified {
                    Text("The private connection has not been verified on this device yet.")
                        .foregroundStyle(.secondary)
                }
                Text(
                    "For the final check, switch your iPhone to mobile data or use another Wi-Fi network, open the Spark in SparkPilot and send a message; Home shows the connection in use."
                )
            }
            Section("If you get stuck") {
                Text(
                    "Check that Tailscale says Connected on this device, and that you used the same account for this device and the Spark; an existing work VPN or a network rule may also prevent the connection."
                )
                Link("Check devices and approvals", destination: RemoteAccessSetupLinks.devices)
                Text(
                    "If the Spark is waiting for approval, approve it in Tailscale’s device list, or ask the person who manages that account; then return here and check again."
                )
            }
            Section("Sharing with someone else") {
                Text(
                    "Your friend uses their own Tailscale account and app; share this Spark with them in Tailscale, then give them a SparkPilot invitation for access inside the app."
                )
                Text(
                    "These are separate permissions: a SparkPilot invitation does not connect their Tailscale network, and sharing a Tailscale device does not grant SparkPilot access."
                )
                Link(
                    "How to share one device in Tailscale",
                    destination: RemoteAccessSetupLinks.sharing
                )
            }
        }
        .navigationTitle("Away from home setup")
        .task { await model.loadIfNeeded() }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else {
                model.invalidatePrivateRouteVerification()
                return
            }
            guard !model.isEnabling, !model.isDisabling, !model.isRefreshing else { return }
            Task { await model.refresh() }
        }
        .toolbar {
            ToolbarItem {
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
                    .disabled(model.isEnabling || model.isDisabling || model.isRefreshing)
            }
        }
    }
}
