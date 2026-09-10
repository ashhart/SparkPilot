import SparkAPI
import SwiftUI

/// Controls the Spark's Tailscale client; the Apple device's VPN remains in the Tailscale app.
struct SparkTailscaleSettingsView: View {
    @Bindable var model: RemoteAccessModel
    @State private var confirmsPause = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Tailscale on this Spark", systemImage: "network.badge.shield.half.filled")
                .font(.headline)
            Text(
                "These settings control the Spark; use the Tailscale app to manage the VPN on this Apple device."
            )
            .font(.footnote).foregroundStyle(.secondary)
            if let preferences = model.overlayPreferences {
                Toggle(
                    "Spark VPN",
                    isOn: Binding(
                        get: { preferences.enabled },
                        set: { enabled in
                            if enabled {
                                Task { await model.resumeOverlayVPN() }
                            } else {
                                confirmsPause = true
                            }
                        }
                    )
                )
                .disabled(!model.canConfigureOverlayPreferences)
                .accessibilityIdentifier("spark.tailscale.vpn")
                Text(
                    preferences.enabled
                        ? String(
                            localized:
                                "The Spark's VPN is enabled; connection status is checked separately."
                        )
                        : String(
                            localized:
                                "The Spark's VPN is paused; its Tailscale account and settings are saved."
                        )
                )
                .font(.footnote).foregroundStyle(.secondary)
                Divider()
                Toggle(
                    "Use Tailscale DNS",
                    isOn: Binding(
                        get: { preferences.acceptDns },
                        set: { enabled in Task { await model.setOverlayDNS(enabled) } }
                    )
                )
                .disabled(!model.canConfigureOverlayPreferences)
                .accessibilityIdentifier("spark.tailscale.dns")
                Text(
                    "Lets this Spark use the DNS servers and MagicDNS names configured in your Tailscale network."
                )
                .font(.footnote).foregroundStyle(.secondary)
            }
            if model.isChangingOverlayPreferences {
                ProgressView { Text("Updating the Spark's Tailscale settings…") }
            } else if let message = model.overlayPreferencesError {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
            } else if model.overlayPreferences == nil {
                Text("VPN and DNS settings have not been read yet.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if model.canRetryOverlayPreferenceChange {
                Button("Retry change") { Task { await model.retryOverlayPreferenceChange() } }
                    .buttonStyle(.bordered)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .alert("Pause the Spark's VPN?", isPresented: $confirmsPause) {
            Button("Pause VPN", role: .destructive) {
                Task { await model.pauseOverlayVPN(confirmed: true) }
            }
            Button("Keep VPN On", role: .cancel) {}
        } message: {
            Text(
                "Remote access to this Spark will disconnect; you will need to be on its local network to turn the VPN back on from SparkPilot."
            )
        }
    }
}
