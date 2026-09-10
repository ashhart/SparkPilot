#if DEBUG
    import Foundation
    import SparkAPI
    import SparkSecurity

    /// Invented settings for the explicitly labelled family-flow preview; no network or keys.
    enum FamilyPreviewWebAccess {
        @MainActor private static var runtimes: [String: Runtime] = [:]
        @MainActor static func model(for target: SparkVoiceTarget) -> SparkAutomationsModel {
            model(route: target.route, targetID: target.id)
        }

        @MainActor static func model(route: URL, targetID: String) -> SparkAutomationsModel {
            let runtime = runtimes[targetID] ?? Runtime()
            runtimes[targetID] = runtime
            return SparkAutomationsModel(
                route: route,
                targetID: targetID,
                runtime: runtime,
                localDeviceRole: "owner",
                userPresenceAuthorizer: Presence()
            )
        }

        private struct Proof: UserPresenceProofSigning {
            let keyInfo = UserPresenceKeyInfo(
                publicKeySPKI: Data([1]),
                protection: .softwareTestOnly
            )
            func proof(for request: UserPresenceCanonicalRequest) async throws -> UserPresenceProof
            {
                throw UserPresenceProofError.signingFailed
            }
        }

        private struct Presence: UserPresenceAuthorizing {
            func keyInfo() async throws -> UserPresenceKeyInfo { Proof().keyInfo }
            func authorize(localizedReason: String) async throws -> any UserPresenceProofSigning {
                Proof()
            }
        }

        private actor Runtime: SparkAutomationManaging {
            var automations: [GeneratedAPI.Automation] = []
            var web = GeneratedAPI.WebAccessSettings(
                policy: .off,
                harnessAccess: false,
                allowDomains: [],
                denyDomains: [],
                searchBackend: .searxng,
                searxngUrl: "http://127.0.0.1:18119",
                braveCredentialId: nil,
                localSearchState: .notInstalled,
                limits: .init(
                    maxToolCalls: 8,
                    maxFetchBytes: 2_097_152,
                    maxRunBytes: 8_388_608,
                    maxRunSeconds: 120,
                    maxRequestSeconds: 20
                ),
                updatedAt: 0
            )
            func getWebAccessSettings(route: URL) async throws -> GeneratedAPI.WebAccessSettings {
                web
            }
            func setWebAccessSettings(
                route: URL,
                request: GeneratedAPI.WebAccessSettingsRequest,
                idempotencyKey: UUID,
                userPresence: any UserPresenceProofSigning
            ) async throws -> SparkAPI.Operation {
                web.policy = .init(rawValue: request.policy.rawValue) ?? .off
                web.localSearchState = .running
                return SparkAPI.Operation(
                    id: idempotencyKey,
                    kind: "settings.web_access",
                    state: .succeeded,
                    cancellable: false
                )
            }
            func operation(route: URL, id: UUID) async throws -> SparkAPI.Operation {
                throw CancellationError()
            }
            func models(route: URL) async throws -> ModelCatalogue {
                try JSONDecoder().decode(
                    ModelCatalogue.self,
                    from: Data(SampleWire.catalogue(.serving).utf8)
                )
            }
            func providerCredentials(route: URL) async throws -> [GeneratedAPI.ProviderCredential] {
                []
            }
            func addProviderCredential(
                route: URL,
                request: GeneratedAPI.AddProviderCredentialRequest,
                idempotencyKey: UUID,
                userPresence: any UserPresenceProofSigning
            ) async throws -> GeneratedAPI.ProviderCredential { throw CancellationError() }
            func listAutomations(route: URL) async throws -> GeneratedAPI.AutomationList {
                .init(items: automations, maxAutomations: 32, observedAt: 0)
            }
            func createAutomation(
                route: URL,
                request: GeneratedAPI.AutomationRequest,
                idempotencyKey: UUID,
                userPresence: (any UserPresenceProofSigning)?
            ) async throws -> GeneratedAPI.Automation {
                let item = GeneratedAPI.Automation(
                    id: idempotencyKey.uuidString,
                    name: request.name,
                    instructions: request.instructions,
                    schedule: request.schedule,
                    modelId: request.modelId,
                    profileId: request.profileId,
                    webAccess: request.webAccess ?? false,
                    delivery: request.delivery ?? .init(notify: false),
                    enabled: request.enabled ?? true,
                    nextRunAt: nil,
                    lastRunAt: nil,
                    lastRunState: .none,
                    createdAt: 0,
                    updatedAt: 0
                )
                automations.append(item)
                return item
            }
            func updateAutomation(
                route: URL,
                id: String,
                request: GeneratedAPI.AutomationUpdateRequest,
                idempotencyKey: UUID,
                userPresence: (any UserPresenceProofSigning)?
            ) async throws -> GeneratedAPI.Automation { throw CancellationError() }
            func deleteAutomation(route: URL, id: String, idempotencyKey: UUID) async throws
                -> GeneratedAPI.AutomationList
            {
                throw CancellationError()
            }
            func runAutomation(route: URL, id: String, idempotencyKey: UUID) async throws
                -> SparkAPI.Operation
            {
                throw CancellationError()
            }
            func listAutomationRuns(route: URL, id: String) async throws
                -> GeneratedAPI.AutomationRunList
            {
                .init(items: [], observedAt: 0)
            }
        }
    }
#endif
