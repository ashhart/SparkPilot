import Foundation
import Observation
import SparkAPI
import SparkBootstrap
import SparkDesignSystem
import SparkSecurity
import SwiftUI

/// Show a one-use invitation for another Apple device to scan.
struct InviteDeviceView: View {
    @Bindable var model: DeviceInvitationModel
    let onDone: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                VStack(spacing: 8) {
                    Text("Add a Device")
                        .font(.largeTitle.bold())
                    Text(.addDeviceInstruction(model.nodeName))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                Picker("What this device may do", selection: $model.role) {
                    ForEach(model.allowedRoles) { role in
                        Text(role.title).tag(role)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(model.isCreating)

                Text(model.role.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                if let errorMessage = model.errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let payload = model.payload {
                    SparkPairingQRCode(payload: payload)
                    Text(
                        "On the new device, open Add Spark, choose Already using SparkPilot? Pair this device, then Pair with QR."
                    )
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    if let joinCode = model.joinCode {
                        DisclosureGroup(String(localized: "Use a six-digit code")) {
                            Text(joinCode.chunkedPairingCode)
                                .font(.system(size: 40, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .textSelection(.enabled)
                                .privacySensitive()
                                .accessibilityLabel(Text(.joinCode(joinCode)))
                            Text(
                                "Use this latest code when the new device cannot scan the QR code."
                            )
                            .font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        Text("Update your Spark to use six-digit pairing; QR pairing is ready now.")
                            .font(.callout).foregroundStyle(.secondary)
                    }

                    if model.isExpired {
                        Label(
                            "This code has expired. Create a new one.",
                            systemImage: "clock.badge.exclamationmark"
                        )
                        .font(.callout)
                        .foregroundStyle(.orange)
                    }

                }

                Text("Approve with Face ID, Touch ID or your device passcode when prompted.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Button(model.payload == nil ? "Create Invitation" : "Create a New Code") {
                    Task { await model.requestInvitation() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.isCreating)

                if model.isCreating {
                    ProgressView(String(localized: "Asking your Spark for an invitation"))
                }
            }
            .frame(maxWidth: 520)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Add a Device")
        .alert(
            "Pair an Administrator Device?",
            isPresented: Binding(
                get: { model.isConfirmingAdministrator },
                set: { if !$0 { model.cancelAdministratorConfirmation() } }
            )
        ) {
            Button("Pair Administrator") {
                Task { await model.confirmAdministratorInvitation() }
            }
            Button("Cancel", role: .cancel) {
                model.cancelAdministratorConfirmation()
            }
        } message: {
            Text(
                """
                This device will be able to manage models, networking, updates, and \
                other devices. It cannot transfer ownership.
                """
            )
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done", action: onDone)
                    .disabled(model.isCreating)
            }
        }
    }
}

extension String {
    fileprivate var chunkedPairingCode: String {
        guard count == 6 else { return self }
        let midpoint = index(startIndex, offsetBy: 3)
        return "\(self[..<midpoint]) \(self[midpoint...])"
    }
}
