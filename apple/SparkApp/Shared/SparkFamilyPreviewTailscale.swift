#if DEBUG
    import Foundation
    import SparkAPI
    import SparkSecurity

    /// In-memory Tailscale controls for the labelled preview, with no network or signing credentials.
    enum FamilyPreviewTailscale {
        @MainActor static func model() -> RemoteAccessModel {
            RemoteAccessModel(
                route: URL(string: "https://tailscale-preview.invalid")!,
                runtime: Runtime(),
                routeRegistration: Routes(),
                userPresenceAuthorizer: Presence(),
                operationDelay: { _ in }
            )
        }

        @MainActor private struct Routes: RemoteAccessRouteRegistering {
            func registerPrivateOverlay(hostname: String, basedOn currentRoute: URL) async throws {}
            func unregisterPrivateOverlay(currentRoute: URL) {}
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

        private actor Runtime: RemoteAccessReading {
            var preferences = GeneratedAPI.RemoteOverlayPreferences(
                provider: .tailscale,
                enabled: true,
                acceptDns: true
            )
            func remoteStatus(route: URL) async throws -> RemoteStatus {
                RemoteStatus(
                    enabled: true,
                    mode: .privateOverlay,
                    health: preferences.enabled ? .healthy : .degraded,
                    hostname: "100.100.1.1",
                    privateOverlayProvider: "tailscale"
                )
            }
            func remoteOverlayPreferences(route: URL) async throws
                -> GeneratedAPI.RemoteOverlayPreferences
            { preferences }
            func configureRemoteOverlay(
                route: URL,
                body: GeneratedAPI.ConfigureRemoteOverlayRequest,
                idempotencyKey: UUID,
                userPresence: any UserPresenceProofSigning
            ) async throws -> SparkAPI.Operation {
                if let enabled = body.enabled { preferences.enabled = enabled }
                if let dns = body.acceptDns { preferences.acceptDns = dns }
                return try await operation(route: route, id: idempotencyKey)
            }
            func operation(route: URL, id: UUID) async throws -> SparkAPI.Operation {
                .init(id: id, kind: "remote.configure", state: .succeeded, cancellable: false)
            }
        }
    }
#endif
