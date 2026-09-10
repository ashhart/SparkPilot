import SparkAPI
import SwiftUI

enum DeviceManagementActionPresentation {
    static let refreshAccessibilityLabel = String(localized: "Refresh paired devices")
    static let retryAccessibilityLabel = String(localized: "Retry loading paired devices")
    static let retryRevocationAccessibilityLabel = String(localized: "Retry device revocation")

    static func revokeAccessibilityLabel(deviceName: String, isRevoking: Bool) -> String {
        isRevoking
            ? String(localized: .revokingAccessFor(deviceName))
            : String(localized: .revokeAccessFor(deviceName))
    }
}

public struct DeviceManagementView: View {
    @Bindable private var model: DeviceManagementModel

    public init(model: DeviceManagementModel) {
        self.model = model
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                heading
                statusMessages
                deviceList
                privacyNote
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .navigationTitle("Devices")
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await model.refresh() }
                } label: {
                    Label("Refresh Devices", systemImage: "arrow.clockwise")
                }
                .disabled(model.isRefreshing || model.revokingDeviceID != nil)
                .accessibilityLabel(
                    DeviceManagementActionPresentation.refreshAccessibilityLabel
                )
                .sparkHelp(
                    String(localized: "Checks the Spark for its current paired-device list.")
                )
            }
        }
        .refreshable { await model.refresh() }
        .task { await model.loadIfNeeded() }
        .alert(
            "Revoke this device?",
            isPresented: confirmationIsPresented,
            presenting: model.revocationConfirmation
        ) { request in
            Button(.revokeResource(request.device.displayName), role: .destructive) {
                Task { await model.confirmRevocation() }
            }
            Button("Cancel", role: .cancel) {
                model.cancelRevocationConfirmation()
            }
        } message: { request in
            Text(
                "This device will lose access to the Spark. The Spark will enforce owner safety rules before making the change."
            )
            .accessibilityLabel(
                Text(.confirmRevoking(request.device.displayName))
            )
        }
    }

    private var confirmationIsPresented: Binding<Bool> {
        Binding(
            get: { model.revocationConfirmation != nil },
            set: { isPresented in
                if !isPresented { model.cancelRevocationConfirmation() }
            }
        )
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Paired devices")
                    .font(.largeTitle.bold())
                SparkTooltipButton(
                    title: String(localized: "Paired devices"),
                    message:
                        String(
                            localized:
                                "These Apple devices have a signed grant from this Spark. Saved details are shown while SparkPilot refreshes."
                        )
                )
            }
            Text("Review which Apple devices the Spark currently trusts.")
                .foregroundStyle(.secondary)
            if !model.devices.isEmpty {
                Text(
                    .trustedOfPaired(
                        trusted: model.trustedDevices.count,
                        paired: model.devices.count
                    )
                )
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var statusMessages: some View {
        if model.isRefreshing, !model.devices.isEmpty {
            Label("Refreshing saved device list", systemImage: "arrow.clockwise")
                .font(.callout)
                .foregroundStyle(.secondary)
        }

        if let message = model.readErrorMessage {
            RecoveryMessage(
                message: message,
                actionTitle: String(localized: "Retry"),
                actionAccessibilityLabel:
                    DeviceManagementActionPresentation.retryAccessibilityLabel
            ) {
                Task { await model.refresh() }
            }
        } else if case .cached(let refreshedAt) = model.freshness {
            Label(
                .deviceListCachedAt(
                    refreshedAt.formatted(date: .abbreviated, time: .standard)
                ),
                systemImage: "clock.arrow.circlepath"
            )
            .font(.callout)
            .foregroundStyle(.orange)
        }

        if let message = model.revocationErrorMessage {
            RecoveryMessage(
                message: message,
                actionTitle: String(localized: "Retry revocation"),
                actionAccessibilityLabel:
                    DeviceManagementActionPresentation.retryRevocationAccessibilityLabel
            ) {
                Task { await model.retryFailedRevocation() }
            }
        }
    }

    @ViewBuilder
    private var deviceList: some View {
        if !model.hasLoaded, model.devices.isEmpty {
            SparkSkeletonList(
                rowCount: 3,
                accessibilityLabel: String(localized: "Loading paired devices")
            )
        } else if model.devices.isEmpty {
            ContentUnavailableView(
                model.freshness == .unavailable ? "Device list unavailable" : "No paired devices",
                systemImage: "laptopcomputer.and.iphone",
                description: Text(
                    model.freshness == .unavailable
                        ? "Reconnect to this Spark and retry."
                        : "This Spark did not report any device grants."
                )
            )
            .frame(maxWidth: .infinity, minHeight: 240)
        } else {
            LazyVStack(spacing: 12) {
                ForEach(model.displayedDevices, id: \.id) { device in
                    DeviceGrantCard(
                        device: device,
                        isLocalDevice: device.id == model.localDeviceID,
                        isRevoking: model.revokingDeviceID == device.id
                    ) {
                        model.requestRevocation(deviceID: device.id)
                    }
                }
            }
        }
    }

    private var privacyNote: some View {
        Label(
            "Paired-device details are cached only on this Apple device. Grants, models, operations, roles, and cluster state remain authoritative on the Spark.",
            systemImage: "externaldrive.badge.checkmark"
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding(.top, 4)
    }
}

private struct RecoveryMessage: View {
    let message: String
    let actionTitle: String
    let actionAccessibilityLabel: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Spacer(minLength: 8)
            Button(actionTitle, action: action)
                .accessibilityLabel(actionAccessibilityLabel)
        }
        .font(.callout)
        .padding(12)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
    }
}

private struct DeviceGrantCard: View {
    let device: GeneratedAPI.Device
    let isLocalDevice: Bool
    let isRevoking: Bool
    let revoke: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: platformSymbol)
                    .font(.title2)
                    .frame(width: 36, height: 36)
                    .background(Color.accentColor.opacity(0.1), in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(device.displayName)
                        .font(.headline)
                    Text(platformLabel)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isLocalDevice {
                    Text("This device")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.blue.opacity(0.12), in: Capsule())
                }
                Text(DeviceGrantPresentation.trustLabel(revoked: device.revoked))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(device.revoked ? .red : .green)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        (device.revoked ? Color.red : Color.green).opacity(0.1),
                        in: Capsule()
                    )
            }

            Grid(alignment: .leading, horizontalSpacing: 22, verticalSpacing: 7) {
                detailRow(String(localized: "Role"), roleLabel)
                detailRow(String(localized: "Paired"), timestampLabel(device.pairedAt))
                detailRow(
                    String(localized: "Last seen"),
                    device.lastSeenAt.map(timestampLabel) ?? String(localized: "Not reported")
                )
            }
            .font(.subheadline)

            if !device.revoked {
                Divider()
                Button(role: .destructive, action: revoke) {
                    if isRevoking {
                        ProgressView()
                    } else {
                        Label("Revoke access", systemImage: "person.crop.circle.badge.minus")
                    }
                }
                .disabled(isRevoking)
                .accessibilityLabel(
                    DeviceManagementActionPresentation.revokeAccessibilityLabel(
                        deviceName: device.displayName,
                        isRevoking: isRevoking
                    )
                )
                .accessibilityHint("Requires confirmation before the Spark changes access.")
                .sparkHelp(
                    String(
                        localized:
                            "Revokes this device after confirmation. The card is restored if the Spark rejects the request."
                    )
                )
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .contain)
    }

    private func detailRow(_ name: String, _ value: String) -> some View {
        GridRow {
            Text(name)
                .foregroundStyle(.secondary)
            Text(value)
                .fontWeight(.medium)
        }
    }

    private var platformLabel: String {
        DeviceGrantPresentation.platformLabel(device.platform)
    }

    private var platformSymbol: String {
        switch device.platform {
        case .ios: "iphone"
        case .ipados: "ipad"
        case .macos: "laptopcomputer"
        }
    }

    private var roleLabel: String { DeviceGrantPresentation.roleLabel(device.role) }

    private func timestampLabel(_ timestamp: String) -> String {
        DeviceGrantPresentation.timestampLabel(timestamp)
    }
}
