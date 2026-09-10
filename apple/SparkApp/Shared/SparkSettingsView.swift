import Foundation
import Observation
import CoreImage.CIFilterBuiltins
import Network
import SparkAPI
import SparkBootstrap
import SparkCore
import SparkDesignSystem
import SparkDiscovery
import SparkSecurity
import SwiftUI

public struct SparkSettingsView: View {
    @State private var pendingWifiForget: String?
    @State private var confirmsStorageCleanup = false
    @Bindable private var model: SparkSettingsModel
    /// The one page to show, or `nil` for every card on one scroll.
    private let group: SparkSettingsGroup?
    private let networkStatus: SparkNetworkStatusModel?
    private let remoteAccess: RemoteAccessModel?
    private let powerControl: SparkPowerControlModel?

    public init(
        model: SparkSettingsModel,
        group: SparkSettingsGroup? = nil,
        networkStatus: SparkNetworkStatusModel? = nil,
        remoteAccess: RemoteAccessModel? = nil,
        powerControl: SparkPowerControlModel? = nil
    ) {
        self.model = model
        self.group = group
        self.networkStatus = networkStatus
        self.remoteAccess = remoteAccess
        self.powerControl = powerControl
    }

    public var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                intro
                if group == .network {
                    // Keep network and remote status reachable while appliance settings are unavailable.
                    networkLinks
                }
                if model.settings == nil, model.isLoading {
                    SparkSkeletonList(
                        rowCount: 5,
                        accessibilityLabel: String(localized: "Loading Spark settings")
                    )
                } else if model.runtimeUpgradeRequired {
                    SparkSettingsRuntimeUpgradeSection(model: model)
                } else if model.settings != nil {
                    groupedSections
                }
                statusMessages
            }
            .frame(maxWidth: 760)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(group?.title ?? "Spark settings")
        .alert(
            "Forget this Wi-Fi network?",
            isPresented: Binding(
                get: { pendingWifiForget != nil },
                set: { if !$0 { pendingWifiForget = nil } }
            )
        ) {
            Button(
                String(
                    localized: .forgetNetworkNamed(
                        pendingWifiForget ?? String(localized: "this network")
                    )
                ),
                role: .destructive
            ) {
                if let ssid = pendingWifiForget { Task { await model.forgetWifi(ssid) } }
                pendingWifiForget = nil
            }
            Button("Cancel", role: .cancel) { pendingWifiForget = nil }
        } message: {
            Text("The Spark will need the password again to reconnect to this network.")
        }
        .alert(
            "Clean selected storage?",
            isPresented: $confirmsStorageCleanup
        ) {
            Button("Clean Selected Storage", role: .destructive) {
                Task { await model.cleanStorage() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The selected unused data will be deleted from this Spark; this cannot be undone.")
        }
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await model.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(model.isLoading || model.activeMutation != nil)
            }
        }
        .task { await model.loadIfNeeded() }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                await model.refreshLiveTelemetry()
            }
        }
        .refreshable { await model.refresh() }
        .sheet(
            isPresented: Binding(
                get: { model.selectedWifiSSID != nil },
                set: {
                    if !$0 {
                        model.selectedWifiSSID = nil
                        model.wifiPassword = ""
                    }
                }
            )
        ) {
            SparkWifiPasswordSheet(model: model)
        }
        // Present SSH host-key confirmation here so first-time runtime installation can complete.
        .hostKeyConfirmationPrompt()
    }

    private var intro: some View {
        SettingsHeader(
            symbol: group?.symbol ?? "slider.horizontal.3",
            title: group?.title ?? String(localized: "Configure your Spark"),
            detail: group?.detail
                ?? String(
                    localized:
                        "Network, hardware, updates, model behaviour and privacy stay under your control."
                )
        )
    }

    /// The cards that belong on this page.
    @ViewBuilder
    private var groupedSections: some View {
        switch group {
        case .network?:
            SparkSettingsNetworkSection(model: model, pendingWifiForget: $pendingWifiForget)
            SparkSettingsTravelSection(model: model)
        case .hardware?:
            SparkSettingsPowerSection(model: model)
            SparkSettingsBluetoothSection(model: model)
        case .updates?:
            SparkSettingsUpdatesSection(model: model, powerControl: powerControl)
        case .models?:
            SparkSettingsMemorySection(model: model)
            SparkSettingsIdleSection(model: model)
        case .storage?:
            SparkSettingsStorageSection(
                model: model,
                confirmsStorageCleanup: $confirmsStorageCleanup
            )
        case .system?:
            SparkSettingsTimeSection(model: model)
            SparkSettingsTelemetrySection(model: model)
        case nil:
            SparkSettingsNetworkSection(model: model, pendingWifiForget: $pendingWifiForget)
            SparkSettingsTravelSection(model: model)
            SparkSettingsBluetoothSection(model: model)
            SparkSettingsPowerSection(model: model)
            SparkSettingsUpdatesSection(model: model, powerControl: powerControl)
            SparkSettingsMemorySection(model: model)
            SparkSettingsIdleSection(model: model)
            SparkSettingsStorageSection(
                model: model,
                confirmsStorageCleanup: $confirmsStorageCleanup
            )
            SparkSettingsTimeSection(model: model)
            SparkSettingsTelemetrySection(model: model)
        }
    }

    @ViewBuilder
    private var networkLinks: some View {
        if let networkStatus {
            NavigationLink {
                SparkNetworkStatusView(model: networkStatus)
            } label: {
                SparkSettingsCardRowLabel(
                    title: String(localized: "Network status"),
                    detail: String(
                        localized: "Interfaces, addresses, link speed and internet reachability"
                    ),
                    symbol: "point.3.connected.trianglepath.dotted"
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open network status")
            .accessibilityHint("Shows the network state reported by this Spark.")
        }
        if let remoteAccess {
            NavigationLink {
                RemoteAccessSettingsView(model: remoteAccess)
            } label: {
                SparkSettingsCardRowLabel(
                    title: String(localized: "Remote access"),
                    detail: String(
                        localized:
                            "Reach this Spark away from home over its private overlay or tunnel"
                    ),
                    symbol: "network.badge.shield.half.filled"
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open remote access")
            .accessibilityHint("Shows how this Spark can be reached away from its network.")
        }
    }

    @ViewBuilder
    private var statusMessages: some View {
        if let active = SparkSettingsProgressPresentation.globalMutationLabel(
            activeMutation: model.activeMutation,
            runtimeUpgradeProgress: model.runtimeUpgradeProgress
        ) {
            ProgressView(active)
        }
        if let success = model.successMessage {
            Label(success, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        }
        if let error = model.errorMessage {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }

}
