import Foundation
import SparkTransport
import SwiftUI
import WebKit

public struct PinnedOpenWebUIRoute: Sendable, Equatable {
    public enum Error: Swift.Error, Sendable, Equatable {
        case insecureBaseRoute
        case invalidAccessPath
        case crossOriginAccessPath
        case missingFingerprint
    }

    public let initialURL: URL
    public let host: String

    public init(baseRoute: URL, accessPath: String) throws {
        guard baseRoute.scheme?.lowercased() == "https", let host = baseRoute.host else {
            throw Error.insecureBaseRoute
        }
        guard accessPath.hasPrefix("/services/open-webui/"),
            let relative = URL(string: accessPath),
            relative.scheme == nil,
            relative.host == nil,
            let resolved = URL(string: accessPath, relativeTo: baseRoute)?.absoluteURL
        else {
            throw Error.invalidAccessPath
        }
        guard resolved.scheme?.lowercased() == "https",
            resolved.host?.lowercased() == host.lowercased()
        else {
            throw Error.crossOriginAccessPath
        }
        self.initialURL = resolved
        self.host = host
    }
}

struct PinnedOpenWebUINavigationPolicy: Sendable, Equatable {
    let host: String

    func allows(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https"
            && url.host?.lowercased() == host.lowercased()
    }
}

struct PinnedOpenWebUISheet: View {
    let route: PinnedOpenWebUIRoute
    let tlsFingerprint: String
    let dismiss: () -> Void

    @State private var failureMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if let failureMessage {
                    ContentUnavailableView(
                        String(localized: "Secure Open WebUI connection failed"),
                        systemImage: "exclamationmark.shield",
                        description: Text(failureMessage)
                    )
                } else {
                    PinnedOpenWebUIBrowser(
                        route: route,
                        tlsFingerprint: tlsFingerprint,
                        onFailure: {
                            failureMessage =
                                String(
                                    localized:
                                        "The service did not present this Spark's saved certificate."
                                )
                        }
                    )
                }
            }
            .navigationTitle("Open WebUI")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: dismiss)
                }
            }
        }
    }
}

#if os(iOS)
    private struct PinnedOpenWebUIBrowser: UIViewRepresentable {
        let route: PinnedOpenWebUIRoute
        let tlsFingerprint: String
        let onFailure: @MainActor () -> Void

        func makeCoordinator() -> Coordinator {
            Coordinator(
                policy: .init(host: route.host),
                trustPolicy: PinnedTrustPolicy(fingerprint: tlsFingerprint),
                onFailure: onFailure
            )
        }

        func makeUIView(context: Context) -> WKWebView {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            let webView = WKWebView(frame: .zero, configuration: configuration)
            webView.navigationDelegate = context.coordinator
            webView.load(URLRequest(url: route.initialURL))
            return webView
        }

        func updateUIView(_ webView: WKWebView, context: Context) {}
    }
#elseif os(macOS)
    private struct PinnedOpenWebUIBrowser: NSViewRepresentable {
        let route: PinnedOpenWebUIRoute
        let tlsFingerprint: String
        let onFailure: @MainActor () -> Void

        func makeCoordinator() -> Coordinator {
            Coordinator(
                policy: .init(host: route.host),
                trustPolicy: PinnedTrustPolicy(fingerprint: tlsFingerprint),
                onFailure: onFailure
            )
        }

        func makeNSView(context: Context) -> WKWebView {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            let webView = WKWebView(frame: .zero, configuration: configuration)
            webView.navigationDelegate = context.coordinator
            webView.load(URLRequest(url: route.initialURL))
            return webView
        }

        func updateNSView(_ webView: WKWebView, context: Context) {}
    }
#endif

@MainActor
private final class Coordinator: NSObject, WKNavigationDelegate {
    private let policy: PinnedOpenWebUINavigationPolicy
    private let trustPolicy: PinnedTrustPolicy
    private let onFailure: @MainActor () -> Void

    init(
        policy: PinnedOpenWebUINavigationPolicy,
        trustPolicy: PinnedTrustPolicy,
        onFailure: @escaping @MainActor () -> Void
    ) {
        self.policy = policy
        self.trustPolicy = trustPolicy
        self.onFailure = onFailure
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url, policy.allows(url) else {
            decisionHandler(.cancel)
            onFailure()
            return
        }
        decisionHandler(.allow)
    }

    func webView(
        _ webView: WKWebView,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler:
            @escaping @MainActor @Sendable (
                URLSession.AuthChallengeDisposition, URLCredential?
            ) -> Void
    ) {
        guard
            challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
            let trust = challenge.protectionSpace.serverTrust
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        switch trustPolicy.evaluate(trust: trust, host: challenge.protectionSpace.host) {
        case .accept:
            completionHandler(.useCredential, URLCredential(trust: trust))
        case .defaultSystem:
            completionHandler(.performDefaultHandling, nil)
        case .reject:
            completionHandler(.cancelAuthenticationChallenge, nil)
            onFailure()
        }
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation?,
        withError error: any Swift.Error
    ) {
        onFailure()
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation?,
        withError error: any Swift.Error
    ) {
        onFailure()
    }
}
