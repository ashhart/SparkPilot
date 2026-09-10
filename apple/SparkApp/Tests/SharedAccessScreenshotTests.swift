import Foundation
import SparkAPI
import SparkSecurity
import Testing

@testable import SparkAppComposition

#if canImport(SwiftUI)
    import SwiftUI

    #if canImport(UIKit)
        import UIKit
    #elseif canImport(AppKit)
        import AppKit
    #endif

    private let screenshotNodeID = "ca890ed7-7c8c-4b2c-9218-b77ef24f569a"
    private let screenshotAuthorityKey = String(repeating: "c", count: 64)
    private let screenshotAuthorityFingerprint =
        "c2f480d4dda9f4522b9f6d590011636d904accfe59f12f9d66a0221c2558e3a2"

    private func screenshotSchedule() -> GeneratedAPI.GuestSchedule {
        GeneratedAPI.GuestSchedule(
            days: (0..<7).map {
                GeneratedAPI.GuestDaySchedule(
                    weekday: $0,
                    windows: [
                        GeneratedAPI.GuestHourWindow(startMinute: 1_020, endMinute: 1_320)
                    ]
                )
            }
        )
    }

    private func screenshotUsage(
        requests: Int,
        refusals: Int,
        prompt: Int,
        completion: Int
    ) -> GeneratedAPI.GuestUsage {
        GeneratedAPI.GuestUsage(
            requests: requests,
            refusals: refusals,
            promptTokens: prompt,
            completionTokens: completion,
            totalTokens: prompt + completion
        )
    }

    private func screenshotGuests() -> [GeneratedAPI.SharedAccessGuest] {
        [
            GeneratedAPI.SharedAccessGuest(
                invitationId: "f2d1c0b9-a897-4655-8443-2211ffeeddcc",
                deviceId: "b1b2b3b4-0000-4000-8000-000000000001",
                displayName: "Sam",
                state: .active,
                allowedModels: ["qwen3-8b", "gemma3-12b"],
                allowedHours: screenshotSchedule(),
                timeZone: "Europe/London",
                maxConcurrentRequests: 1,
                dailyTokenBudget: 50_000,
                joinedAt: "2026-08-30T18:12:00Z",
                confirmedAt: "2026-08-30T18:14:00Z",
                lastSeenAt: "2026-09-04T20:41:00Z",
                today: screenshotUsage(requests: 12, refusals: 0, prompt: 9_100, completion: 6_400),
                thisWeek: screenshotUsage(
                    requests: 61,
                    refusals: 4,
                    prompt: 41_000,
                    completion: 28_500
                ),
                refusalsThisWeek: ["GUEST_OUTSIDE_HOURS": 3, "GUEST_MODEL_NOT_ALLOWED": 1]
            ),
            GeneratedAPI.SharedAccessGuest(
                invitationId: "aa11bb22-cc33-4d44-9e55-6f7788990011",
                deviceId: "b1b2b3b4-0000-4000-8000-000000000002",
                displayName: "Robin",
                state: .pending,
                allowedModels: ["qwen3-8b"],
                allowedHours: screenshotSchedule(),
                timeZone: "Europe/London",
                maxConcurrentRequests: 1,
                dailyTokenBudget: 20_000,
                joinedAt: "2026-09-04T21:58:00Z",
                today: screenshotUsage(requests: 0, refusals: 1, prompt: 0, completion: 0),
                thisWeek: screenshotUsage(requests: 0, refusals: 1, prompt: 0, completion: 0),
                refusalsThisWeek: ["GUEST_AWAITING_OWNER": 1]
            ),
        ]
    }

    private func screenshotSelf() -> GeneratedAPI.SharedAccessSelf {
        GeneratedAPI.SharedAccessSelf(
            displayName: "Sam",
            state: .active,
            allowedModels: ["qwen3-8b", "gemma3-12b"],
            allowedHours: screenshotSchedule(),
            timeZone: "Europe/London",
            maxConcurrentRequests: 1,
            dailyTokenBudget: 50_000,
            today: screenshotUsage(requests: 12, refusals: 0, prompt: 9_100, completion: 6_400),
            budgetResetsAt: 1_788_000_000
        )
    }

    private func screenshotInvitation() -> GeneratedAPI.SharedAccessInvitation {
        GeneratedAPI.SharedAccessInvitation(
            invitation: GeneratedAPI.PairingInvitation(
                version: 2,
                nodeId: screenshotNodeID,
                localEndpoint: "https://alex-s-Spark-8cd8b1ab.local:7443",
                remoteEndpoint: "https://spark-example.tail1234.ts.net:7443",
                authorityFingerprint: screenshotAuthorityFingerprint,
                invitationId: "63e82da2-7fb7-4b4b-9584-4a528000ac94",
                nonce: "_gauBKJ2S7qD4YEg3YXkJLJ9pVCy4rc-PV4yJSGP3_Q",
                role: .guest,
                expiresAt: "2026-09-12T18:00:00Z",
                nodeName: "Alex's Spark",
                tlsFingerprint: String(repeating: "a", count: 64),
                remoteHostname: "spark-example.tail1234.ts.net",
                signature: String(repeating: "s", count: 43),
                additionalProperties: [:]
            ),
            nodeName: "Alex's Spark",
            tlsFingerprint: String(repeating: "a", count: 64),
            authorityPublicKey: screenshotAuthorityKey,
            localEndpoint: "https://alex-s-Spark-8cd8b1ab.local:7443",
            remoteHostname: "spark-example.tail1234.ts.net"
        )
    }

    private final class ScreenshotPresence: UserPresenceProofSigning, @unchecked Sendable {
        let keyInfo: UserPresenceKeyInfo
        private let signer = SoftwareSigner()

        init() {
            keyInfo = UserPresenceKeyInfo(
                publicKeySPKI: signer.publicKeySPKI,
                protection: .softwareTestOnly
            )
        }

        func proof(for request: UserPresenceCanonicalRequest) async throws -> UserPresenceProof {
            try UserPresenceProof.sign(request) { try signer.sign($0) }
        }
    }

    private actor ScreenshotAuthorizer: UserPresenceAuthorizing {
        private let signer = SoftwareSigner()

        func keyInfo() async throws -> UserPresenceKeyInfo {
            UserPresenceKeyInfo(
                publicKeySPKI: signer.publicKeySPKI,
                protection: .softwareTestOnly
            )
        }

        func authorize(localizedReason: String) async throws -> any UserPresenceProofSigning {
            ScreenshotPresence()
        }
    }

    private struct ScreenshotRuntime: SharedAccessProviding, OwnSharedAccessProviding {
        func sharedAccess(route: URL) async throws -> GeneratedAPI.SharedAccessOverview {
            GeneratedAPI.SharedAccessOverview(guests: screenshotGuests())
        }

        func ownSharedAccess(route: URL) async throws -> GeneratedAPI.SharedAccessSelf {
            screenshotSelf()
        }

        func createSharedAccessInvitation(
            route: URL,
            limits: GeneratedAPI.CreateSharedAccessInvitation,
            idempotencyKey: UUID,
            userPresence: any UserPresenceProofSigning
        ) async throws -> GeneratedAPI.SharedAccessInvitation {
            screenshotInvitation()
        }

        func updateSharedAccess(
            route: URL,
            deviceID: String,
            change: GeneratedAPI.UpdateSharedAccess,
            idempotencyKey: UUID,
            userPresence: any UserPresenceProofSigning
        ) async throws -> GeneratedAPI.SharedAccessGuest {
            screenshotGuests()[0]
        }

        func revokeSharedAccess(
            route: URL,
            deviceID: String,
            idempotencyKey: UUID,
            userPresence: any UserPresenceProofSigning
        ) async throws -> GeneratedAPI.SharedAccessRevocation {
            GeneratedAPI.SharedAccessRevocation(deviceId: deviceID, state: .revoked)
        }
    }

    private func screenshotTrust() -> NodeTrust {
        NodeTrust(
            nodeID: screenshotNodeID,
            nodeName: "Alex's Spark",
            tlsFingerprint: String(repeating: "a", count: 64),
            authorityFingerprint: screenshotAuthorityFingerprint,
            authorityPublicKey: screenshotAuthorityKey,
            pairedAt: Date(timeIntervalSince1970: 1_780_000_000),
            localDeviceRole: "owner"
        )
    }

    /// Render the shared-access screens for review. Skipped unless a folder is set.
    @MainActor
    struct SharedAccessScreenshots {
        @Test func renderSharedAccessScreensForReview() async throws {
            guard let folder = ProcessInfo.processInfo.environment["SHARED_ACCESS_QA_DIRECTORY"]
            else { return }
            let directory = URL(fileURLWithPath: folder)
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            for (name, view) in try await Self.screens() {
                #if canImport(AppKit) && !canImport(UIKit)
                    let framed = AnyView(view.formStyle(.grouped))
                #else
                    let framed = view
                #endif
                let png = try #require(Self.png(of: framed))
                try png.write(to: directory.appendingPathComponent("\(name).png"))
            }
        }

        /// Host the view in a real window before capturing, because a List cannot be drawn offscreen.
        static func png(of view: some View) -> Data? {
            let size = CGSize(width: 393, height: 852)
            #if canImport(UIKit)
                let controller = UIHostingController(rootView: AnyView(view))
                controller.view.frame = CGRect(origin: .zero, size: size)
                controller.view.layoutIfNeeded()
                let renderer = UIGraphicsImageRenderer(size: size)
                return renderer.image { _ in
                    controller.view.drawHierarchy(
                        in: controller.view.bounds,
                        afterScreenUpdates: true
                    )
                }
                .pngData()
            #elseif canImport(AppKit)
                let hosting = NSHostingView(rootView: AnyView(view))
                hosting.frame = CGRect(origin: .zero, size: size)
                let window = NSWindow(
                    contentRect: hosting.frame,
                    styleMask: [.titled],
                    backing: .buffered,
                    defer: false
                )
                window.contentView = hosting
                window.displayIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.4))
                window.displayIfNeeded()
                guard
                    let representation = hosting.bitmapImageRepForCachingDisplay(
                        in: hosting.bounds
                    )
                else { return nil }
                hosting.cacheDisplay(in: hosting.bounds, to: representation)
                return representation.representation(using: .png, properties: [:])
            #else
                return nil
            #endif
        }

        static func screens() async throws -> [(String, AnyView)] {
            let route = URL(string: "https://alex-s-Spark-8cd8b1ab.local:7443")!
            let runtime = ScreenshotRuntime()
            let owner = SharedAccessModel(
                route: route,
                runtime: runtime,
                userPresenceAuthorizer: ScreenshotAuthorizer()
            )
            await owner.refresh()

            let guest = GuestExperienceModel(route: route, runtime: runtime)
            await guest.load()

            let invite = SharedAccessInvitationModel(
                route: route,
                trust: screenshotTrust(),
                runtime: runtime,
                availableModels: ["qwen3-8b", "gemma3-12b", "gpt-oss-120b"],
                userPresenceAuthorizer: ScreenshotAuthorizer(),
                draft: SharedAccessLimitsDraft(
                    guestName: "Sam",
                    allowedModels: ["qwen3-8b"],
                    startMinute: 1_020,
                    endMinute: 1_320,
                    timeZone: "Europe/London",
                    maxConcurrentRequests: 1,
                    dailyTokenBudget: 50_000
                )
            )
            let shared = SharedAccessInvitationModel(
                route: route,
                trust: screenshotTrust(),
                runtime: runtime,
                availableModels: ["qwen3-8b", "gemma3-12b", "gpt-oss-120b"],
                userPresenceAuthorizer: ScreenshotAuthorizer(),
                draft: invite.draft
            )
            await shared.createInvitation()

            return [
                (
                    "shared-access-owner",
                    AnyView(NavigationStack { SharedAccessView(model: owner) {} })
                ),
                (
                    "shared-access-invite",
                    AnyView(NavigationStack { SharedAccessInviteView(model: invite) {} })
                ),
                (
                    "shared-access-share",
                    AnyView(NavigationStack { SharedAccessInviteView(model: shared) {} })
                ),
                (
                    "shared-access-guest",
                    AnyView(
                        NavigationStack {
                            GuestAccessView(model: guest, nodeName: "Alex's Spark")
                        }
                    )
                ),
            ]
        }
    }
#endif
