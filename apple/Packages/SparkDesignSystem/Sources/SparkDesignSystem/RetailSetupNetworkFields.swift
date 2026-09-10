import Foundation
import SparkCore
import SwiftUI

struct RetailSetupNetworkFields: View {
    @Binding var setupSSID: String
    @Binding var setupPassphrase: String
    @Binding var isSetupPasswordVisible: Bool
    let canScanQuickStartCode: Bool
    /// QA-02: the setup network this device is actually associated with, when there is one.
    let detectedSetupSSID: String?

    private var status: RetailSetupNetworkStatus {
        .resolve(ssid: setupSSID, detectedSSID: detectedSetupSSID, passphrase: setupPassphrase)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Spark setup Wi-Fi", systemImage: "wifi")
                .font(.headline)

            VStack(spacing: 0) {
                setupSSIDField
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)

                Divider()
                    .padding(.leading, 14)

                HStack(spacing: 10) {
                    if isSetupPasswordVisible {
                        TextField("Wi-Fi password", text: $setupPassphrase)
                            .textContentType(.password)
                    } else {
                        SecureField("Wi-Fi password", text: $setupPassphrase)
                            .textContentType(.password)
                    }

                    Button {
                        isSetupPasswordVisible.toggle()
                    } label: {
                        Image(systemName: isSetupPasswordVisible ? "eye.slash" : "eye")
                            .frame(width: 28, height: 44)
                            .contentShape(Rectangle())
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        isSetupPasswordVisible ? "Hide Wi-Fi password" : "Show Wi-Fi password"
                    )
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
            }
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 14))

            Text(status.passwordRule)
                .font(.caption)
                .foregroundStyle(status.passwordRuleIsUnmet ? Color.orange : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(setupNetworkHelp)
                .font(.caption)
                .foregroundStyle(.secondary)

            // Disclose that NVIDIA's pre-runtime setup sends Wi-Fi credentials over plain HTTP on the temporary hotspot.
            Label {
                Text(
                    """
                    This first step uses the Spark's own temporary setup \
                    network, which is not encrypted. Anyone within range who \
                    joined it could read this password. Everything after setup \
                    is encrypted and pinned to your Spark.
                    """
                )
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .font(.caption)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)

            if status.showsFoundConfirmation {
                Label(.readyToJoin(setupSSID), systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else if status.showsNotSeenNote {
                Label(.setupNetworkNotSeen(setupSSID), systemImage: "wifi.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: 440)
    }

    private var setupNetworkHelp: String {
        canScanQuickStartCode
            ? String(
                localized:
                    "Enter the whole network name, or just the start of it and this device will show every Spark network that matches."
            )
            : String(
                localized:
                    "Enter the whole network name and password printed on the Spark Quick Start card."
            )
    }

    @ViewBuilder
    private var setupSSIDField: some View {
        #if os(iOS)
            TextField("Spark Wi-Fi name", text: $setupSSID)
                .textContentType(.username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        #else
            TextField("Spark Wi-Fi name", text: $setupSSID)
                .textContentType(.username)
        #endif
        if !setupSSID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            SparkSetupAddress.hostname(for: setupSSID) == nil
        {
            Text(
                "This network name cannot be used for manual setup; scan the Spark Quick Start code or use the setup name printed on its card."
            )
            .font(.caption)
            .foregroundStyle(.red)
            .accessibilityLabel("The Spark setup network name is not supported for manual entry.")
        }
    }

}
