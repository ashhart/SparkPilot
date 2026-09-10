import Foundation

/// What the owner is told before turning remote access on, in plain words with every technical term glossed.
public enum RemoteAccessExplanation {
    public static var thirdPartyNotice: String {
        String(
            localized:
                "Tailscale is a separate app and service from Tailscale Inc.; it manages your account and VPN connection, while SparkPilot checks access to your Spark."
        )
    }
    public struct Section: Equatable, Sendable {
        public let title: String
        public let points: [String]
    }

    public struct Term: Equatable, Sendable {
        public let term: String
        public let meaning: String
    }

    /// The whole promise in one sentence, above the button.
    public static var oneTapSummary: String {
        String(
            localized: """
                Your Spark can set up Tailscale for you. Create or use a Tailscale account, install \
                its app on this device, then sign the Spark in to the same account. We check the \
                private connection before calling it ready; at home your local connection still works.
                """
        )
    }

    public static var whatItIs: Section {
        Section(
            title: String(localized: "What Tailscale is"),
            points: [
                String(
                    localized: """
                        Tailscale is a private network between your own devices. It is built on \
                        WireGuard, a modern encryption protocol, so your devices talk to each other \
                        over encrypted connections, directly when possible or through a relay when needed.
                        """
                )
            ]
        )
    }

    public static var whatItDoes: Section {
        Section(
            title: String(localized: "What it does for your Spark"),
            points: [
                String(
                    localized: """
                        Your Spark joins that private network under your account, so this app can reach \
                        it from anywhere: on your network it still connects directly, and away from it \
                        SparkPilot connects over Tailscale on its own.
                        """
                )
            ]
        )
    }

    public static var howSecure: Section {
        Section(
            title: String(localized: "How secure it is"),
            points: [
                String(
                    localized:
                        "Traffic is encrypted end to end between your device and the Spark."
                ),
                String(
                    localized: """
                        Your Tailscale access rules determine which devices can reach the Spark, including \
                        people you invite. SparkPilot access is granted separately.
                        """
                ),
                String(
                    localized: """
                        No port on your router is opened and nothing about the Spark is published on \
                        the public internet.
                        """
                ),
                String(
                    localized: """
                        SparkPilot still checks the Spark's own certificate and signs every request, \
                        exactly as it does at home. Tailscale carries the connection; it never unlocks \
                        the Spark.
                        """
                ),
            ]
        )
    }

    public static var whatLeavesYourHome: Section {
        Section(
            title: String(localized: "What leaves your home"),
            points: [
                String(
                    localized: """
                        Tailscale's coordination service learns that your Spark exists: its device key \
                        and its public internet address, so your devices can find each other. It never \
                        sees your chats, files or the Spark's data.
                        """
                ),
                String(
                    localized: """
                        When a direct connection between your device and the Spark is not possible, the \
                        traffic goes through a Tailscale relay, still encrypted end to end so the relay \
                        cannot read it.
                        """
                ),
                String(
                    localized: """
                        Tailscale may relay encrypted traffic; it cannot read the chat or file contents \
                        inside that connection.
                        """
                ),
            ]
        )
    }

    public static var whatYouNeed: Section {
        Section(
            title: String(localized: "What you need"),
            points: [
                String(
                    localized:
                        "A Tailscale account, created using Apple, Google or another supported sign-in; review Tailscale’s current plans when you join."
                ),
                String(
                    localized: """
                        The Tailscale app on this iPhone, iPad or Mac, signed in to the same account, \
                        for the times you are away from your network.
                        """
                ),
                String(
                    localized:
                        "A minute to sign the Spark in from your browser the first time."
                ),
            ]
        )
    }

    public static var whatChanges: Section {
        Section(
            title: String(localized: "What changes"),
            points: [
                String(
                    localized:
                        "The Spark installs or starts the Tailscale client and keeps it running."
                ),
                String(
                    localized: """
                        The Spark gets a Tailscale name, like spark-example.tail1234.ts.net. It becomes a \
                        second address in this app; your local address keeps working.
                        """
                ),
                String(
                    localized: """
                        Developer tools: over Tailscale the Spark's own API address is \
                        https://<its Tailscale name>:7443/v1, not the .local name. Anything you set up \
                        with the local address needs that address when you use it away from home.
                        """
                ),
            ]
        )
    }

    public static var sections: [Section] {
        [whatItIs, whatItDoes, howSecure, whatLeavesYourHome, whatYouNeed, whatChanges]
    }

    public static var glossary: [Term] {
        [
            Term(
                term: String(localized: "WireGuard"),
                meaning: String(
                    localized: "The encryption protocol Tailscale is built on."
                )
            ),
            Term(
                term: String(localized: "Tailnet"),
                meaning: String(localized: "Your private Tailscale network.")
            ),
            Term(
                term: String(localized: "Tailscale name"),
                meaning: String(
                    localized:
                        "The address Tailscale gives each device, ending in .ts.net (Tailscale calls this MagicDNS)."
                )
            ),
        ]
    }

    /// What happens while the app waits for the owner's sign-in.
    public static var signInInstructions: String {
        String(
            localized: """
                Sign in to Tailscale to finish. Open the link on this device or scan the code with \
                another one; the Spark notices on its own and finishes the setup. The link works for \
                ten minutes.
                """
        )
    }
}
