#if os(macOS)
    import AppKit
    import Foundation
    import Network
    import Observation
    import SparkAPI
    import SparkCore
    import SparkSecurity
    @_spi(SparkInternal) import SparkTransport

    public enum SparkDeveloperTool: String, CaseIterable, Identifiable, Sendable {
        case claudeCode
        case codexApp
        case hermesAgent
        case ohMyPi
        case openCode

        public var id: String { rawValue }

        public var name: String {
            switch self {
            case .claudeCode: String(localized: "Claude Code")
            case .codexApp: String(localized: "Codex App")
            case .hermesAgent: String(localized: "Hermes Agent")
            case .ohMyPi: String(localized: "Oh My Pi")
            case .openCode: String(localized: "OpenCode")
            }
        }

        public var summary: String {
            switch self {
            case .claudeCode: String(localized: "Anthropic's coding agent")
            case .codexApp: String(localized: "OpenAI's desktop coding agent")
            case .hermesAgent: String(localized: "Nous Research's agent with tools")
            case .ohMyPi: String(localized: "A coding agent with local tools")
            case .openCode: String(localized: "An open-source coding agent")
            }
        }

        public var symbol: String {
            switch self {
            case .claudeCode: "terminal"
            case .codexApp: "app"
            case .hermesAgent: "brain.head.profile"
            case .ohMyPi: "terminal.fill"
            case .openCode: "chevron.left.forwardslash.chevron.right"
            }
        }

        public var installHint: String {
            switch self {
            case .claudeCode: String(localized: "Install Claude Code, then try again.")
            case .codexApp: String(localized: "Install the Codex app, then try again.")
            case .hermesAgent: String(localized: "Install Hermes Agent, then try again.")
            case .ohMyPi: String(localized: "Install Oh My Pi, then try again.")
            case .openCode: String(localized: "Install OpenCode, then try again.")
            }
        }
    }

    public enum SparkDeveloperToolLaunchState: Equatable, Sendable {
        case idle
        case starting
        case launched
        case failed(String)
    }

    @MainActor
    public protocol SparkDeveloperToolLaunching: AnyObject {
        func launch(_ tool: SparkDeveloperTool, target: SparkChatTarget) async throws
    }

    @MainActor
    @Observable
    public final class SparkDeveloperToolsModel {
        public private(set) var catalogue: SparkChatTargetCatalogue = .empty
        public var selectedTargetID: String? {
            didSet {
                if selectedTargetID != oldValue {
                    launchStates.removeAll()
                    stopEndpoint()
                }
            }
        }
        public private(set) var launchStates: [SparkDeveloperTool: SparkDeveloperToolLaunchState] =
            [:]

        public private(set) var endpoint: SparkIntegrationEndpoint?
        public private(set) var endpointStarting = false
        public private(set) var endpointError: String?
        private var endpointTarget: SparkChatTarget?
        private var endpointAttempt = UUID()
        private var endpointGateway: (any SparkIntegrationGatewayServing)?
        private let gatewayFactory: (SparkChatTarget) -> any SparkIntegrationGatewayServing

        private let targetProvider: any SparkChatTargetProviding
        private let launcher: any SparkDeveloperToolLaunching

        public init(
            targetProvider: any SparkChatTargetProviding,
            launcher: any SparkDeveloperToolLaunching,
            gatewayFactory: ((SparkChatTarget) -> any SparkIntegrationGatewayServing)? = nil
        ) {
            self.targetProvider = targetProvider
            self.launcher = launcher
            self.gatewayFactory = gatewayFactory ?? { SparkIntegrationGateway(target: $0) }
            refresh()
        }

        public var selectedTarget: SparkChatTarget? {
            catalogue.targets.first { $0.id == selectedTargetID }
        }

        public func refresh() {
            let next = targetProvider.catalogue()
            catalogue = next
            if let endpointTarget, !next.targets.contains(endpointTarget) {
                stopEndpoint()
            }
            if next.targets.contains(where: { $0.id == selectedTargetID }) {
                return
            }
            selectedTargetID = next.targets.first?.id
        }

        isolated deinit { endpointGateway?.stop() }

        public func startEndpoint() async {
            guard !endpointStarting, endpoint == nil else { return }
            let attempt = UUID()
            endpointAttempt = attempt
            endpointStarting = true
            endpointError = nil
            refresh()
            guard endpointAttempt == attempt else { return }
            guard let target = selectedTarget else {
                endpointStarting = false
                return
            }
            let gateway = gatewayFactory(target)
            endpointGateway = gateway
            endpointTarget = target
            do {
                let connection = try await gateway.start()
                guard endpointAttempt == attempt, selectedTarget == target else {
                    gateway.stop()
                    return
                }
                endpoint = connection
                endpointStarting = false
            } catch {
                gateway.stop()
                guard endpointAttempt == attempt else { return }
                endpointGateway = nil
                endpointTarget = nil
                endpointStarting = false
                endpointError =
                    (error as? LocalizedError)?.errorDescription
                    ?? String(describing: error)
            }
        }

        public func stopEndpoint() {
            endpointAttempt = UUID()
            endpointGateway?.stop()
            endpointGateway = nil
            endpointTarget = nil
            endpoint = nil
            endpointStarting = false
            endpointError = nil
        }

        public func state(for tool: SparkDeveloperTool) -> SparkDeveloperToolLaunchState {
            launchStates[tool] ?? .idle
        }

        public func launch(_ tool: SparkDeveloperTool) async {
            guard let target = selectedTarget else { return }
            launchStates[tool] = .starting
            do {
                try await launcher.launch(tool, target: target)
                launchStates[tool] = .launched
            } catch {
                launchStates[tool] = .failed(
                    (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                )
            }
        }
    }

    public enum SparkDeveloperToolLaunchError: LocalizedError {
        case appNotInstalled(SparkDeveloperTool)
        case invalidGatewayRequest
        case gatewayUnavailable(String)
        case identityMismatch
        case incompatibleModel(String)
        case selectedModelChanged
        case terminalUnavailable
        case unsupportedContent(String)

        public var errorDescription: String? {
            switch self {
            case .appNotInstalled(let tool): tool.installHint
            case .invalidGatewayRequest:
                String(localized: "The local launcher received an invalid request.")
            case .gatewayUnavailable(let reason):
                String(localized: .developerBridgeUnavailable(reason))
            case .identityMismatch:
                String(localized: "The Spark no longer proves the identity paired with this Mac.")
            case .incompatibleModel(let reason): reason
            case .selectedModelChanged:
                String(
                    localized:
                        "The selected model is no longer running; choose a current model and try again."
                )
            case .terminalUnavailable:
                String(localized: "Spark could not open the launch command in Terminal.")
            case .unsupportedContent(let reason): reason
            }
        }
    }

#endif
