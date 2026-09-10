import SparkAPI
import SparkDesignSystem
import SwiftUI
#if os(iOS)
    import SafariServices
#endif

/// The explanation the owner reads before turning remote access on: plain words, every term glossed.
struct RemoteAccessExplanationView: View {
    @State private var showsDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(RemoteAccessExplanation.thirdPartyNotice)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(RemoteAccessExplanation.oneTapSummary)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            DisclosureGroup(isExpanded: $showsDetails) {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(RemoteAccessExplanation.sections, id: \.title) { section in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(section.title).font(.subheadline.weight(.semibold))
                            ForEach(section.points, id: \.self) { point in
                                Label {
                                    Text(point)
                                } icon: {
                                    Image(systemName: "circle.fill")
                                        .font(.system(size: 5))
                                        .padding(.top, 7)
                                }
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Words used above").font(.subheadline.weight(.semibold))
                        ForEach(RemoteAccessExplanation.glossary, id: \.term) { term in
                            Text(.labelledValue(title: term.term, value: term.meaning))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.top, 6)
            } label: {
                Text("How it works and how secure it is")
                    .font(.subheadline.weight(.medium))
            }
            .accessibilityHint("Explains Tailscale, its security, what you need and what changes.")
        }
    }
}

/// The owner's single step: sign in to Tailscale from this device or by scanning the code with another.
struct RemoteAccessSignInCard: View {
    let url: URL?
    let waitingForApproval: Bool
    var openSignIn: ((URL) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(
                waitingForApproval
                    ? String(localized: "Waiting for your tailnet to approve the Spark")
                    : String(localized: "Sign in to Tailscale to finish"),
                systemImage: "person.badge.key"
            )
            .font(.headline)
            Text(
                waitingForApproval
                    ? String(
                        localized:
                            "Your tailnet requires an administrator to approve new devices. Approve the Spark in the Tailscale admin console; the Spark finishes on its own."
                    )
                    : RemoteAccessExplanation.signInInstructions
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
            if waitingForApproval {
                Link("Open Tailscale devices", destination: RemoteAccessSetupLinks.devices)
            }
            if let url {
                Group {
                    if let openSignIn {
                        Button {
                            openSignIn(url)
                        } label: {
                            Label("Open Tailscale Sign-In", systemImage: "safari")
                        }
                    } else {
                        Link(destination: url) {
                            Label("Open Tailscale Sign-In", systemImage: "safari")
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .accessibilityHint("Opens Tailscale's sign-in page in your browser.")
                SparkPairingQRCode(payload: url.absoluteString, size: 200)
                    .accessibilityLabel("Tailscale sign-in code")
                    .accessibilityHint("Scan with another device to sign the Spark in from there.")
                Text(url.absoluteString)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } else if !waitingForApproval {
                ProgressView(String(localized: "Asking the Spark for its sign-in link…"))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// Progress while the Spark works: a single line per stage, never a raw operation state.
struct RemoteAccessTurnOnProgress: View {
    let phase: RemoteAccessTurnOnPhase

    private var line: String? {
        switch phase {
        case .reviewing: String(localized: "Checking what the Spark needs…")
        case .preparing: String(localized: "Setting Tailscale up on the Spark…")
        case .verifying: String(localized: "Checking the Spark answers over Tailscale…")
        case .finishing: String(localized: "Recording the new route on this device…")
        default: nil
        }
    }

    var body: some View {
        if let line {
            HStack(spacing: 10) {
                ProgressView()
                Text(line).font(.subheadline)
            }
            .accessibilityElement(children: .combine)
        }
    }
}

/// A failure never ends in a raw error: it names what happened and the one thing to do next.
struct RemoteAccessNextActionCard: View {
    let action: RemoteAccessNextAction
    let tryAgain: () -> Void
    let checkAgain: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(action.title, systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            Text(action.message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                switch action.kind {
                case .tryAgain:
                    Button("Try Again", action: tryAgain).buttonStyle(.borderedProminent)
                case .checkAgain, .openTailscaleOnThisDevice:
                    Button("Check Again", action: checkAgain).buttonStyle(.borderedProminent)
                case .none:
                    EmptyView()
                }
                Button("Dismiss", action: dismiss).buttonStyle(.bordered)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct RemoteAccessEnableControls: View {
    @Bindable var model: RemoteAccessModel
    @State private var signInPage: RemoteSignInPage?
    @Environment(\.openURL) private var openURL
    var body: some View {
        Group {
            switch model.turnOnPhase {
            case .idle, .done:
                Button {
                    Task { await model.turnOn() }
                } label: {
                    Label("Turn On Remote Access", systemImage: "bolt.horizontal.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canTurnOn)
                .accessibilityHint(
                    "Sets Tailscale up on the Spark and asks you to sign in once."
                )
            case .awaitingSignIn:
                RemoteAccessSignInCard(
                    url: model.signInURL,
                    waitingForApproval: false,
                    openSignIn: openSignIn
                )
            case .awaitingApproval:
                RemoteAccessSignInCard(
                    url: model.signInURL,
                    waitingForApproval: true,
                    openSignIn: openSignIn
                )
            case .reviewing, .preparing, .verifying, .finishing:
                RemoteAccessTurnOnProgress(phase: model.turnOnPhase)
            case .failed(let action):
                RemoteAccessNextActionCard(
                    action: action,
                    tryAgain: {
                        model.dismissTurnOnOutcome()
                        Task { await model.turnOn() }
                    },
                    checkAgain: {
                        model.dismissTurnOnOutcome()
                        Task { await model.recheckRemoteHealth() }
                    },
                    dismiss: { model.dismissTurnOnOutcome() }
                )
            }
        }
        #if os(iOS)
            .sheet(item: $signInPage, onDismiss: { Task { await model.refreshAfterReturning() } }) {
                page in
                RemoteSignInBrowser(url: page.url).ignoresSafeArea()
            }
        #endif
        .onChange(of: model.turnOnPhase) { _, phase in
            // Completion comes from the signed Spark operation, never from inspecting the web page.
            if phase != .awaitingSignIn && phase != .awaitingApproval { signInPage = nil }
        }
    }

    private func openSignIn(_ url: URL) {
        guard RemoteOverlaySetup.isTrustedSignInLink(url) else { return }
        #if os(iOS)
            signInPage = RemoteSignInPage(url: url)
        #else
            openURL(url)
        #endif
    }
}

private struct RemoteSignInPage: Identifiable {
    let url: URL
    var id: URL { url }
}

#if os(iOS)
    private struct RemoteSignInBrowser: UIViewControllerRepresentable {
        let url: URL
        func makeUIViewController(context: Context) -> SFSafariViewController {
            let browser = SFSafariViewController(url: url)
            browser.dismissButtonStyle = .close
            return browser
        }
        func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
    }
#endif
