import SparkDiscovery

/// QA-03: what the pairing screen is entitled to claim about the Spark it is about to pair with.
enum PairThisDeviceEvidence: Equatable, Sendable {
    /// The Spark answered discovery on this network, so the confirmation is earned.
    case foundOnNetwork
    /// The owner typed an address and nothing has contacted it; pairing is the first attempt.
    case addressTypedByHand
    /// No Spark chosen yet — a join code or invitation is being entered on its own.
    case noTarget

    /// The identifier a typed address is given when it becomes a pairing target.
    static let typedAddressPrefix = "manual:"

    static func resolve(_ target: DiscoveredSpark?) -> PairThisDeviceEvidence {
        guard let target else { return .noTarget }
        return target.id.hasPrefix(typedAddressPrefix) ? .addressTypedByHand : .foundOnNetwork
    }

    var showsConnectedArtwork: Bool { self == .foundOnNetwork }

    var saysNothingHasBeenChecked: Bool { self == .addressTypedByHand }
}

/// QA-06: which of this screen's two pairing actions a failure belongs to.
enum PairThisDeviceAttempt: Equatable, Sendable {
    case joinCode
    case invitation
}

/// QA-06: where a pairing failure is drawn, so it lands under the button that was tapped rather than two screens up.
enum PairThisDeviceErrorPlacement: Equatable, Sendable {
    case aboveTheForm
    case underJoinCode
    case underInvitation

    static func resolve(_ attempt: PairThisDeviceAttempt?) -> PairThisDeviceErrorPlacement {
        switch attempt {
        case .none: .aboveTheForm
        case .joinCode: .underJoinCode
        case .invitation: .underInvitation
        }
    }
}
