import Foundation

/// Stable catalogue keys with typed interpolation arguments for Connect, remote access and the developer endpoint.
extension LocalizedStringResource {
    static func connectTo(_ target: String) -> Self {
        .init(
            "fleet.connect.to",
            defaultValue: "Connect to \(target)",
            comment:
                "Accessible name for the button that connects to a named Spark, on its network or over Tailscale."
        )
    }

    static func tailscaleReachableAs(_ host: String) -> Self {
        .init(
            "remote.tailscale.reachable.host",
            defaultValue: "Reachable over Tailscale as \(host)",
            comment: "The Spark's Tailscale name once remote access is on."
        )
    }

    static func sparkAPIAddressOverTailscale(_ url: String) -> Self {
        .init(
            "developer.endpoint.tailscale",
            defaultValue: """
                Right now this Spark is reached over Tailscale, so its own API address is \(url). \
                A tool set up with the Spark's local address needs this one instead.
                """,
            comment:
                "Developer tools: the OpenAI-compatible base URL differs while the Spark is reached over Tailscale."
        )
    }

    static func sparkAPIAddressOnYourNetwork(_ url: String) -> Self {
        .init(
            "developer.endpoint.local",
            defaultValue: """
                On your network this Spark's own API address is \(url). \
                Over Tailscale it changes to the Spark's Tailscale name.
                """,
            comment:
                "Developer tools: the OpenAI-compatible base URL while the Spark is on the local network."
        )
    }
}

/// What an unfinished one-tap enable actually left running, said in one sentence per outcome.
extension LocalizedStringResource {
    static func remoteSignInExpired(state: String) -> Self {
        .init(
            "remote.turn.on.sign.in.expired",
            defaultValue:
                "Tap Turn On Remote Access again for a fresh link, then sign in within ten minutes. \(state)",
            comment: "The Tailscale sign-in window closed, followed by what the Spark reports."
        )
    }

    static func remoteSetupFailed(state: String) -> Self {
        .init(
            "remote.turn.on.setup.failed",
            defaultValue:
                "Try again; if it fails again, sign the Spark in yourself with `sudo tailscale up`. \(state)",
            comment: "The Spark could not set Tailscale up, followed by what it reports is running."
        )
    }

    static func remoteRouteUnverified(state: String) -> Self {
        .init(
            "remote.turn.on.route.unverified",
            defaultValue: "Give the Spark a moment, then check again. \(state)",
            comment: "Tailscale signed in but the route did not answer, and what the Spark reports."
        )
    }

    static func remoteEnableCancelled(state: String) -> Self {
        .init(
            "remote.turn.on.cancelled",
            defaultValue: "Tap Turn On Remote Access to start again. \(state)",
            comment: "The enable was cancelled, followed by what the Spark reports is running."
        )
    }

    static func remoteEnableUnfinished(state: String) -> Self {
        .init(
            "remote.turn.on.unfinished",
            defaultValue:
                "The Spark could not finish turning it on. Try again while near your Spark. \(state)",
            comment: "An enable that failed for no named reason, and what the Spark reports."
        )
    }
}
