import SwiftUI

/// Explain private remote access with colour-independent health and an explicit disable action (§17).
public struct RemoteAccessCardState: Equatable, Sendable {
    public let enabled: Bool
    public let mode: RemoteAccessModeValue
    public let health: RemoteAccessHealthValue
    public let hostname: String?

    public init(
        enabled: Bool,
        mode: RemoteAccessModeValue,
        health: RemoteAccessHealthValue,
        hostname: String? = nil
    ) {
        self.enabled = enabled
        self.mode = mode
        self.health = health
        self.hostname = hostname
    }
}

public enum RemoteAccessModeValue: String, Sendable, Equatable {
    case disabled
    case privateOverlay = "private_overlay"
}

public enum RemoteAccessHealthValue: String, Sendable, Equatable {
    case disabled
    case starting
    case healthy
    case degraded
    case failed
}

/// Resolved copy for one remote state.
public struct RemoteAccessPresentation: Equatable, Sendable {
    public let title: String
    public let detail: String
    public let symbol: String
    public let showsDisable: Bool
    public let showsHostname: Bool
    public let disableTitle: String

    public init(
        title: String,
        detail: String,
        symbol: String,
        showsDisable: Bool,
        showsHostname: Bool,
        disableTitle: String = String(localized: "Turn Off Remote Access")
    ) {
        self.title = title
        self.detail = detail
        self.symbol = symbol
        self.showsDisable = showsDisable
        self.showsHostname = showsHostname
        self.disableTitle = disableTitle
    }
}

public enum RemoteAccessPresentationResolver {
    public static func resolve(_ state: RemoteAccessCardState) -> RemoteAccessPresentation {
        switch (state.enabled, state.mode) {
        case (false, _), (true, .disabled):
            return RemoteAccessPresentation(
                title: String(localized: "Remote Access Off"),
                detail: String(localized: "SparkPilot is not using a remote route for this Spark."),
                symbol: "house.fill",
                showsDisable: false,
                showsHostname: false
            )
        case (true, .privateOverlay):
            switch state.health {
            case .healthy:
                return RemoteAccessPresentation(
                    title: String(localized: "Private Route Ready"),
                    detail:
                        String(
                            localized:
                                "SparkPilot can use your existing overlay route. The Spark certificate and device signature are still required."
                        ),
                    symbol: "lock.shield.fill",
                    showsDisable: true,
                    showsHostname: true,
                    disableTitle: String(localized: "Stop Using Private Route")
                )
            case .starting:
                return RemoteAccessPresentation(
                    title: String(localized: "Checking Private Route"),
                    detail: String(
                        localized: "SparkPilot is authenticating the selected overlay address."
                    ),
                    symbol: "hourglass",
                    showsDisable: true,
                    showsHostname: true,
                    disableTitle: String(localized: "Stop Using Private Route")
                )
            case .degraded, .failed:
                return RemoteAccessPresentation(
                    title: String(localized: "Private Route Needs Attention"),
                    detail:
                        String(
                            localized:
                                "The overlay route is unavailable. Keep using the Spark locally, check the overlay client, or stop using this route."
                        ),
                    symbol: "exclamationmark.shield.fill",
                    showsDisable: true,
                    showsHostname: true,
                    disableTitle: String(localized: "Stop Using Private Route")
                )
            case .disabled:
                return RemoteAccessPresentation(
                    title: String(localized: "Remote Access Off"),
                    detail: String(
                        localized: "SparkPilot is not using a remote route for this Spark."
                    ),
                    symbol: "house.fill",
                    showsDisable: false,
                    showsHostname: false
                )
            }

        }
    }

    /// Explain private remote access before it is enabled.
    public static func modeExplanation(_ mode: RemoteAccessModeValue) -> String {
        switch mode {
        case .privateOverlay:
            return
                String(
                    localized:
                        "SparkPilot uses the private address from your existing overlay. The provider may relay encrypted packets, while SparkPilot still pins and signs the Spark connection."
                )
        case .disabled:
            return String(
                localized: "SparkPilot uses only the local routes saved on this Apple device."
            )
        }
    }
}

/// Card presenting remote state with hostname and the Disable action.
public struct RemoteAccessCard: View {
    public let state: RemoteAccessCardState
    public let onDisable: () -> Void

    public init(state: RemoteAccessCardState, onDisable: @escaping () -> Void = {}) {
        self.state = state
        self.onDisable = onDisable
    }

    public var body: some View {
        let presentation = RemoteAccessPresentationResolver.resolve(state)
        VStack(alignment: .leading, spacing: 10) {
            Label(presentation.title, systemImage: presentation.symbol)
                .font(.headline)

            Text(presentation.detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if presentation.showsHostname, let hostname = state.hostname {
                LabeledContent("Address", value: hostname)
                    .font(.subheadline.monospaced())
                    .textSelection(.enabled)
            }

            if presentation.showsDisable {
                Button(presentation.disableTitle, action: onDisable)
                    .buttonStyle(.bordered)
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// Offer Tailscale remote access before changing configuration.
public struct RemoteAccessSetupView: View {
    public let onSelectMode: (RemoteAccessModeValue) -> Void

    public init(onSelectMode: @escaping (RemoteAccessModeValue) -> Void = { _ in }) {
        self.onSelectMode = onSelectMode
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Turn On Remote Access?")
                .font(.title3.weight(.semibold))

            Text("Use Tailscale to reach this Spark when you are away from home.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            modeRow(
                title: String(localized: "Through Tailscale"),
                mode: .privateOverlay
            )
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func modeRow(title: String, mode: RemoteAccessModeValue) -> some View {
        Button {
            onSelectMode(mode)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(RemoteAccessPresentationResolver.modeExplanation(mode))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(
                .quaternary.opacity(0.5),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
        }
        .buttonStyle(.plain)
    }
}
