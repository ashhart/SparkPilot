import Foundation

/// Provides testable headings and actions for every native setup step.
enum NativeSparkSetupPresentation {
    struct Heading: Equatable {
        let title: String
        let message: String
    }

    /// Truthful about the default first-boot transport: cleartext, but confined to the setup Wi-Fi.
    static var unencryptedTransportNotice: String {
        String(
            localized:
                "This first-boot page is not encrypted. Your details travel only over the Spark’s own setup Wi-Fi, directly between this device and the Spark."
        )
    }

    static func heading(for step: NativeSparkSetupStep) -> Heading {
        switch step {
        case .region:
            Heading(
                title: String(localized: "Language and time zone"),
                message: String(
                    localized:
                        "We’ve selected settings from this device. Check them before continuing."
                )
            )
        case .licence:
            Heading(
                title: String(localized: "Terms for your Spark"),
                message: String(
                    localized: """
                        These NVIDIA and system terms were supplied directly by your Spark. \
                        The app has not replaced or rewritten them.
                        """
                )
            )
        case .account:
            Heading(
                title: String(localized: "Create your Spark account"),
                message: String(
                    localized: """
                        This is the Spark's own login: the account you sign in with on a \
                        connected screen, or over SSH when you are not using keys. The app \
                        sends the password directly to the Spark and clears it after setup.
                        """
                )
            )
        case .privacy:
            Heading(
                title: String(localized: "NVIDIA's privacy choices"),
                message: String(
                    localized: """
                        These choices are NVIDIA's, for the Spark's own software, and are \
                        sent to NVIDIA. They have nothing to do with SparkPilot, which sends \
                        no telemetry. Both can stay off.
                        """
                )
            )
        case .wifi:
            Heading(
                title: String(localized: "Connect your Spark to the internet"),
                message: String(
                    localized: """
                        Use Ethernet for the most reliable setup, or choose the Wi-Fi \
                        network the Spark should use every day.
                        """
                )
            )
        case .connecting:
            Heading(
                title: String(localized: "Connecting your Spark"),
                message: String(
                    localized: """
                        The temporary Spark network will disappear. This device will \
                        reconnect, then find the Spark on your Wi-Fi.
                        """
                )
            )
        }
    }

    /// Display the setup network name verbatim in the password heading.
    static func networkHeading(name: String, isProtected: Bool) -> Heading {
        Heading(
            title: String(localized: .joinNetwork(name)),
            message: isProtected
                ? String(
                    localized:
                        "Enter the password for this Wi-Fi network. It goes directly to your Spark."
                )
                : String(localized: "This Wi-Fi network does not require a password.")
        )
    }

    /// Distinguish continuing over Ethernet from joining Wi-Fi in the primary action.
    static func primaryAction(
        step: NativeSparkSetupStep,
        ethernetHasInternet: Bool,
        hasSelectedNetwork: Bool
    ) -> String {
        switch step {
        case .region, .licence, .account, .privacy:
            String(localized: "Continue")
        case .wifi:
            ethernetHasInternet && !hasSelectedNetwork
                ? String(localized: "Continue with Ethernet")
                : String(localized: "Connect Spark")
        // The step runs itself; there is nothing for the owner to press.
        case .connecting:
            ""
        }
    }
}
