import Foundation
import SwiftUI
#if os(iOS)
    import UIKit
#elseif os(macOS)
    import AppKit
#endif

enum TailscaleAppDestination: Equatable { case application, appStore, unavailable }

@MainActor
struct TailscaleAppHandoff {
    static let appURL = URL(string: "tailscale://")!
    static var storeURL: URL {
        #if os(macOS)
            URL(string: "https://apps.apple.com/app/tailscale/id1475387142")!
        #else
            URL(string: "https://apps.apple.com/app/tailscale/id1470499037")!
        #endif
    }
    let canOpenApplication: () -> Bool
    let openApplication: () async -> Bool
    let openStore: () async -> Bool

    func open() async -> TailscaleAppDestination {
        if canOpenApplication(), await openApplication() { return .application }
        guard !Task.isCancelled else { return .unavailable }
        return await openStore() ? .appStore : .unavailable
    }

    static var system: Self {
        #if os(iOS)
            Self(
                canOpenApplication: { UIApplication.shared.canOpenURL(appURL) },
                openApplication: { await UIApplication.shared.open(appURL) },
                openStore: { await UIApplication.shared.open(storeURL) }
            )
        #else
            Self(
                canOpenApplication: { NSWorkspace.shared.urlForApplication(toOpen: appURL) != nil },
                openApplication: {
                    guard let application = NSWorkspace.shared.urlForApplication(toOpen: appURL)
                    else { return false }
                    do {
                        _ = try await NSWorkspace.shared.openApplication(
                            at: application,
                            configuration: .init()
                        )
                        return true
                    } catch { return false }
                },
                openStore: { NSWorkspace.shared.open(storeURL) }
            )
        #endif
    }
}

struct TailscaleOpenAppButton: View {
    @State private var isOpening = false
    @State private var destination: TailscaleAppDestination?
    var beforeOpening: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                beforeOpening()
                isOpening = true
                Task {
                    destination = await TailscaleAppHandoff.system.open()
                    isOpening = false
                }
            } label: {
                Label("Connect via Tailscale", systemImage: "arrow.up.forward.app")
                    .frame(minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isOpening)
            .accessibilityHint(
                "Opens the separate Tailscale app, or its App Store page if it is not installed"
            )
            if isOpening {
                ProgressView(String(localized: "Opening Tailscale…"))
            } else if destination == .unavailable {
                Text(
                    "Tailscale could not be opened; try again or open it from this device's Home screen or Applications folder."
                )
                .font(.footnote).foregroundStyle(.secondary)
                Link("Tailscale in the App Store", destination: TailscaleAppHandoff.storeURL)
            } else if destination == .appStore {
                Text(
                    "Install Tailscale, open it and sign in, then come back here to check your Spark connection."
                )
                .font(.footnote).foregroundStyle(.secondary)
            } else {
                Text(
                    "In Tailscale, turn the connection on and use the same account as your Spark; then return to SparkPilot."
                )
                .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}

struct TailscaleConnectionStatusView: View {
    @Bindable var model: RemoteAccessModel
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.isRefreshing {
                ProgressView(String(localized: "Checking your Spark over Tailscale…"))
            } else if model.isPrivateRouteVerified {
                Label {
                    Text("Connected via Tailscale")
                } icon: {
                    Image(systemName: "checkmark.shield.fill").foregroundStyle(.green)
                }
                Text(
                    "This device reached your Spark over its private connection during the latest check."
                )
                .font(.footnote).foregroundStyle(.secondary)
            } else {
                Label("Tailscale connection not verified", systemImage: "network.slash")
                Text(
                    "Opening Tailscale does not confirm a connection; sign in, turn it on and check again here."
                )
                .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
