import Foundation
import SparkAPI
import SparkDesignSystem
import Testing

@testable import SparkAppComposition

/// Checks connectivity state labels and confines runtime data to the fields designated for it.
private func readableCopy(_ text: String, _ what: String) {
    #expect(!text.isEmpty, "\(what) says nothing")
    #expect(text.trimmingCharacters(in: .whitespaces) == text, "\(what) is padded")
    #expect(!text.contains("_"), "\(what) shows an identifier")
    #expect(!text.contains("://"), "\(what) shows a route")
}

// MARK: - Remote access

@Test func everyRemoteModeAndHealthResolvesItsOwnCopy() {
    let modes: [RemoteAccessModeValue] = [.disabled, .privateOverlay]
    let healths: [RemoteAccessHealthValue] = [.disabled, .starting, .healthy, .degraded, .failed]
    var resolved: Set<String> = []
    for enabled in [true, false] {
        for mode in modes {
            for health in healths {
                let state = RemoteAccessCardState(
                    enabled: enabled,
                    mode: mode,
                    health: health,
                    hostname: "spark-example.tail1234.ts.net"
                )
                let presentation = RemoteAccessPresentationResolver.resolve(state)
                let what = "\(enabled) \(mode) \(health)"
                readableCopy(presentation.title, "\(what) title")
                readableCopy(presentation.detail, "\(what) detail")
                readableCopy(presentation.disableTitle, "\(what) disable action")
                #expect(!presentation.symbol.isEmpty)
                // Display the hostname only as field data rather than weaving it into explanatory copy.
                #expect(!presentation.title.contains("tail1234"))
                #expect(!presentation.detail.contains("tail1234"))
                resolved.insert(presentation.title)
                // A card with nothing to turn off offers no button.
                if !presentation.showsDisable {
                    #expect(!presentation.showsHostname)
                }
            }
        }
    }
    // Cover disabled, private remote-access transitions.
    #expect(resolved.count == 4, "the remote states do not read as four distinct things")
}

@Test func everyModeExplainsWhatItMeansBeforeItIsChosen() {
    var explanations: Set<String> = []
    for mode in [RemoteAccessModeValue.disabled, .privateOverlay] {
        let text = RemoteAccessPresentationResolver.modeExplanation(mode)
        readableCopy(text, "\(mode) explanation")
        #expect(text.hasSuffix("."), "\(mode) explanation is not a sentence")
        explanations.insert(text)
    }
    #expect(explanations.count == 2, "two modes are explained the same way")
}

// MARK: - Network interfaces

@Test func everyInterfaceTypeAndStateReadsAsWords() {
    var types: Set<String> = []
    for type in ["ethernet", "wifi", "bridge", "loopback", "thunderbolt-bridge-9"] {
        let label = NetworkInterfacePresentation.typeLabel(type)
        readableCopy(label, "type \(type)")
        #expect(label != type, "\(type) is shown as its own token")
        types.insert(label)
    }
    #expect(types.count == 5, "two interface types read the same")

    var states: Set<String> = []
    for state in ["connected", "disconnected", "unavailable", "some_future_state"] {
        let label = NetworkInterfacePresentation.stateLabel(state)
        readableCopy(label, "state \(state)")
        #expect(label != state)
        states.insert(label)
    }
    #expect(states.count == 4, "two interface states read the same")
}

/// Distinguish cable, router, gateway and DNS recovery guidance.
@Test func everyConnectivityOutcomeSaysWhichOneItIs() {
    let outcomes: [(String, String)] = [
        (
            "down",
            NetworkInterfacePresentation.internetLabel(
                state: "disconnected",
                reachable: false,
                gatewayReachable: nil,
                dnsReachable: nil
            )
        ),
        (
            "reachable",
            NetworkInterfacePresentation.internetLabel(
                state: "connected",
                reachable: true,
                gatewayReachable: true,
                dnsReachable: true
            )
        ),
        (
            "no gateway",
            NetworkInterfacePresentation.internetLabel(
                state: "connected",
                reachable: false,
                gatewayReachable: false,
                dnsReachable: nil
            )
        ),
        (
            "no dns",
            NetworkInterfacePresentation.internetLabel(
                state: "connected",
                reachable: false,
                gatewayReachable: true,
                dnsReachable: false
            )
        ),
        (
            "unexplained",
            NetworkInterfacePresentation.internetLabel(
                state: "connected",
                reachable: false,
                gatewayReachable: nil,
                dnsReachable: nil
            )
        ),
    ]
    var seen: Set<String> = []
    for (name, label) in outcomes {
        readableCopy(label, "connectivity \(name)")
        seen.insert(label)
    }
    #expect(seen.count == outcomes.count, "two connectivity outcomes read the same")
}

/// Treat network names as data and format signal proportions as localised percentages.
@Test func theWiFiRowNamesTheNetworkAndFormatsItsSignal() {
    let name = "Café Réseau 5G"
    #expect(NetworkInterfacePresentation.wifiValue(name: name, signalPercent: nil) == name)
    let withSignal = NetworkInterfacePresentation.wifiValue(name: name, signalPercent: 72)
    #expect(withSignal.contains(name), "the network's own name was changed")
    #expect(withSignal.contains(72.formatted()) || withSignal.contains("72"))
    #expect(withSignal != name)
}

@Test func linkSpeedSwitchesToGigabitWhereTheCableIsLabelledInGigabit() {
    let megabit = NetworkInterfacePresentation.linkSpeed(100)
    let gigabit = NetworkInterfacePresentation.linkSpeed(10_000)
    readableCopy(megabit, "100 Mb link")
    readableCopy(gigabit, "10 Gb link")
    #expect(megabit != gigabit)
    #expect(!gigabit.contains("10000"), "a 10 GbE cable is not labelled 10000")
}

// MARK: - First-run setup

@Test func everySetupStepHasAHeadingAndAnAction() {
    var titles: Set<String> = []
    for step in NativeSparkSetupStep.allCases {
        let heading = NativeSparkSetupPresentation.heading(for: step)
        readableCopy(heading.title, "\(step) title")
        readableCopy(heading.message, "\(step) message")
        #expect(heading.title != heading.message)
        titles.insert(heading.title)

        let action = NativeSparkSetupPresentation.primaryAction(
            step: step,
            ethernetHasInternet: false,
            hasSelectedNetwork: false
        )
        // The connecting step runs itself and offers no button.
        if step == .connecting {
            #expect(action.isEmpty)
        } else {
            readableCopy(action, "\(step) action")
        }
    }
    #expect(titles.count == NativeSparkSetupStep.allCases.count, "two steps share a heading")
}

/// Label Ethernet continuation separately from Wi-Fi joining.
@Test func theNetworkStepSaysWhichWayItWillConnect() {
    let ethernet = NativeSparkSetupPresentation.primaryAction(
        step: .wifi,
        ethernetHasInternet: true,
        hasSelectedNetwork: false
    )
    let wifi = NativeSparkSetupPresentation.primaryAction(
        step: .wifi,
        ethernetHasInternet: true,
        hasSelectedNetwork: true
    )
    readableCopy(ethernet, "ethernet action")
    readableCopy(wifi, "wifi action")
    #expect(ethernet != wifi)
}

/// Keep network names verbatim while varying password guidance.
@Test func theNetworkPasswordHeadingNamesTheNetworkAndSaysWhetherOneIsNeeded() {
    let name = "Réseau-Privé"
    let locked = NativeSparkSetupPresentation.networkHeading(name: name, isProtected: true)
    let open = NativeSparkSetupPresentation.networkHeading(name: name, isProtected: false)
    #expect(locked.title.contains(name))
    #expect(open.title == locked.title)
    #expect(locked.message != open.message, "an open network is asked for a password")
    readableCopy(locked.message, "protected network message")
    readableCopy(open.message, "open network message")
}

// MARK: - Paired devices

@Test func everyDeviceRoleAndTrustStateReadsAsWords() {
    var roles: Set<String> = []
    for role in [GeneratedAPI.Role.owner, .administrator, .developer, .user, .observer] {
        let label = DeviceGrantPresentation.roleLabel(role)
        readableCopy(label, "role \(role)")
        #expect(label != role.rawValue, "\(role) is shown as its own token")
        roles.insert(label)
    }
    #expect(roles.count == 5, "two roles read the same")

    // Red and green capsules; the word inside carries the same fact.
    let trusted = DeviceGrantPresentation.trustLabel(revoked: false)
    let revoked = DeviceGrantPresentation.trustLabel(revoked: true)
    readableCopy(trusted, "trusted")
    readableCopy(revoked, "revoked")
    #expect(trusted != revoked, "trust is told apart only by colour")
}

@Test func everyPlatformNamesItsProduct() {
    var platforms: Set<String> = []
    for platform in [GeneratedAPI.DevicePlatform.ios, .ipados, .macos] {
        let label = DeviceGrantPresentation.platformLabel(platform)
        readableCopy(label, "platform \(platform)")
        #expect(label != platform.rawValue)
        platforms.insert(label)
    }
    #expect(platforms.count == 3)
}

/// Format valid pairing timestamps for the reader and label unparseable ones missing.
@Test func aPairingTimestampIsFormattedAndAnUnreadableOneIsNamed() {
    for wire in ["2026-08-31T09:15:00Z", "2026-08-31T09:15:00.250Z"] {
        let shown = DeviceGrantPresentation.timestampLabel(wire)
        #expect(!shown.contains("T"), "\(wire) was shown as it arrived")
        #expect(!shown.contains("Z"))
        #expect(shown != wire)
    }
    let unreadable = "whenever-the-newer-runtime-says"
    let shown = DeviceGrantPresentation.timestampLabel(unreadable)
    #expect(!shown.contains(unreadable))
    #expect(shown == String(localized: "Not reported"))
}

/// Name the affected device and current state in revoke accessibility labels.
@Test func theRevokeActionNamesItsDeviceInBothStates() {
    let name = "Alex's iPhone"
    let idle = DeviceManagementActionPresentation.revokeAccessibilityLabel(
        deviceName: name,
        isRevoking: false
    )
    let running = DeviceManagementActionPresentation.revokeAccessibilityLabel(
        deviceName: name,
        isRevoking: true
    )
    #expect(idle.contains(name))
    #expect(running.contains(name))
    #expect(idle != running, "a revocation in flight reads as one not started")
}
