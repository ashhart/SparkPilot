import CryptoKit
import Foundation
import SparkAPI
import SparkSecurity
import Testing

@testable import SparkAppComposition

/// Verifies explicit presence-gated export, disabled sensitive defaults and owner-only archive permissions.
@MainActor
struct DiagnosticsExportTests {
    // MARK: - Doubles

    private static func catalogue() -> GeneratedAPI.DiagnosticsCatalogue {
        GeneratedAPI.DiagnosticsCatalogue(
            observedAt: "2026-09-01T00:00:00Z",
            sections: [
                section(id: "runtime", sensitivity: .operational, byDefault: true),
                section(id: "host", sensitivity: .operational, byDefault: true),
            ],
            optionalCategories: [
                section(id: "network-addresses", sensitivity: .identifying, byDefault: false),
                section(id: "host-paths", sensitivity: .identifying, byDefault: false),
            ],
            neverExported: [
                GeneratedAPI.DiagnosticsExclusion(
                    id: "prompts",
                    title: "Prompts and responses",
                    reason: "Not retained by the runtime."
                )
            ]
        )
    }

    private static func section(
        id: String,
        sensitivity: GeneratedAPI.DiagnosticsSectionSensitivity,
        byDefault: Bool
    ) -> GeneratedAPI.DiagnosticsSection {
        GeneratedAPI.DiagnosticsSection(
            id: id,
            title: id.capitalized,
            description: "Contents of \(id).",
            sensitivity: sensitivity,
            includedByDefault: byDefault
        )
    }

    private static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func bundle(optional included: [String]) -> GeneratedAPI.DiagnosticsBundle {
        GeneratedAPI.DiagnosticsBundle(
            manifest: GeneratedAPI.DiagnosticsManifest(
                schema: 1,
                generatedAt: "2026-09-01T00:00:00Z",
                nodeId: "1f8a1b3e-0000-4000-8000-000000000001",
                runtimeVersion: "0.1.0",
                files: [
                    GeneratedAPI.DiagnosticsManifestEntry(
                        path: "runtime.json",
                        sensitivity: .operational,
                        description: "Runtime version.",
                        bytes: 2,
                        sha256: Self.digest("{}")
                    )
                ],
                optionalIncluded: included,
                optionalExcluded: ["network-addresses", "host-paths"].filter {
                    !included.contains($0)
                },
                neverExported: []
            ),
            files: [
                GeneratedAPI.DiagnosticsFile(
                    path: "runtime.json",
                    sensitivity: .operational,
                    content: "{}"
                )
            ]
        )
    }

    private final class Service: DiagnosticsExporting, @unchecked Sendable {
        var catalogueResult: Result<GeneratedAPI.DiagnosticsCatalogue, Error>
        var bundleResult: Result<GeneratedAPI.DiagnosticsBundle, Error>
        private(set) var requestedCategories: [[String]] = []
        private(set) var presenceProofs = 0

        init(
            catalogue: GeneratedAPI.DiagnosticsCatalogue,
            bundle: GeneratedAPI.DiagnosticsBundle
        ) {
            catalogueResult = .success(catalogue)
            bundleResult = .success(bundle)
        }

        func diagnosticsCatalogue(route: URL) async throws -> GeneratedAPI.DiagnosticsCatalogue {
            try catalogueResult.get()
        }

        func exportDiagnostics(
            route: URL,
            includeOptional: [String],
            userPresence: any UserPresenceProofSigning
        ) async throws -> GeneratedAPI.DiagnosticsBundle {
            requestedCategories.append(includeOptional)
            presenceProofs += 1
            return try bundleResult.get()
        }
    }

    private final class Authorizer: UserPresenceAuthorizing, @unchecked Sendable {
        var failure: Error?
        private(set) var reasons: [String] = []

        func keyInfo() async throws -> UserPresenceKeyInfo {
            StubProof().keyInfo
        }

        func authorize(localizedReason: String) async throws -> any UserPresenceProofSigning {
            reasons.append(localizedReason)
            if let failure { throw failure }
            return StubProof()
        }
    }

    private struct StubProof: UserPresenceProofSigning {
        var keyInfo: UserPresenceKeyInfo {
            UserPresenceKeyInfo(publicKeySPKI: Data(), protection: .softwareTestOnly)
        }

        func proof(for request: UserPresenceCanonicalRequest) async throws -> UserPresenceProof {
            throw UserPresenceProofError.sessionConsumed
        }
    }

    /// Inject interrupted, partial, out-of-space and flush failures into archive writes.
    private final class ScriptedFileIO: DiagnosticsFileIO, @unchecked Sendable {
        enum Behaviour {
            case interruptAlternately
            case failAfterFirstByte
            case failSync
        }

        private let behaviour: Behaviour
        private let lock = NSLock()
        private var calls = 0
        private var _interruptions = 0

        var interruptions: Int {
            lock.lock()
            defer { lock.unlock() }
            return _interruptions
        }

        init(behaviour: Behaviour) {
            self.behaviour = behaviour
        }

        func write(
            _ descriptor: Int32,
            _ buffer: UnsafeRawPointer,
            _ count: Int
        ) -> (written: Int, errno: Int32) {
            lock.lock()
            calls += 1
            let call = calls
            lock.unlock()

            switch behaviour {
            case .interruptAlternately:
                if call.isMultiple(of: 2) {
                    lock.lock()
                    _interruptions += 1
                    lock.unlock()
                    return (-1, EINTR)
                }
                // Write one byte per call to exercise partial-write handling.
                return (Foundation.write(descriptor, buffer, min(1, count)), 0)
            case .failAfterFirstByte:
                if call == 1 { return (Foundation.write(descriptor, buffer, min(1, count)), 0) }
                return (-1, ENOSPC)
            case .failSync:
                return (Foundation.write(descriptor, buffer, count), 0)
            }
        }

        func synchronize(_ descriptor: Int32) -> Int32 {
            behaviour == .failSync ? EIO : 0
        }
    }

    private static func model(
        service: Service,
        authorizer: Authorizer = Authorizer(),
        writer: DiagnosticsArchiveWriter = DiagnosticsArchiveWriter()
    ) -> DiagnosticsExportModel {
        DiagnosticsExportModel(
            route: URL(string: "https://spark.invalid")!,
            service: service,
            userPresenceAuthorizer: authorizer,
            writer: writer
        )
    }

    /// Uses a fixed destination to make duplicate export paths collide deterministically.
    private static func fixedWriter(
        directory: URL,
        name: String
    ) -> DiagnosticsArchiveWriter {
        DiagnosticsArchiveWriter(directory: directory, nextName: { name })
    }

    private static func scratchDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("diagnostics-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Owner controls

    @Test func everySensitiveCategoryStartsOff() async {
        let service = Service(catalogue: Self.catalogue(), bundle: Self.bundle(optional: []))
        let model = Self.model(service: service)
        await model.load()

        #expect(model.optionalCategories.count == 2)
        #expect(model.selectedCategories.isEmpty)
        for category in model.optionalCategories {
            #expect(model.isSelected(category.id) == false)
        }
    }

    @Test func theControlsCanOnlyOfferCategoriesTheRuntimeDescribed() async {
        let service = Service(catalogue: Self.catalogue(), bundle: Self.bundle(optional: []))
        let model = Self.model(service: service)
        await model.load()

        model.setSelected("prompts", true)
        #expect(
            model.selectedCategories.isEmpty,
            "a never-exported id must not become a selection"
        )
        model.setSelected("host-paths", true)
        #expect(model.selectedCategories == ["host-paths"])
    }

    @Test func exportSendsOnlyTheTickedCategories() async {
        let service = Service(
            catalogue: Self.catalogue(),
            bundle: Self.bundle(optional: ["host-paths"])
        )
        let model = Self.model(service: service)
        await model.load()
        model.setSelected("host-paths", true)

        let archive = await model.export()
        #expect(archive != nil)
        #expect(service.requestedCategories == [["host-paths"]])
        #expect(service.presenceProofs == 1)
        defer { archive.map { try? FileManager.default.removeItem(at: $0.url) } }
    }

    @Test func exportRequiresLocalPresenceAndSendsNothingWithoutIt() async {
        let service = Service(catalogue: Self.catalogue(), bundle: Self.bundle(optional: []))
        let authorizer = Authorizer()
        authorizer.failure = UserPresenceProofError.sessionConsumed
        let model = Self.model(service: service, authorizer: authorizer)
        await model.load()

        let archive = await model.export()
        #expect(archive == nil)
        #expect(service.requestedCategories.isEmpty, "the request left before presence succeeded")
        #expect(model.failure != nil)
        #expect(authorizer.reasons.count == 1)
    }

    // MARK: - The file the owner holds

    @Test func theArchiveIsCreatedOwnerOnlyRatherThanNarrowedAfterwards() async throws {
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = Service(catalogue: Self.catalogue(), bundle: Self.bundle(optional: []))
        let model = Self.model(
            service: service,
            writer: Self.fixedWriter(directory: directory, name: "bundle.json")
        )
        await model.load()

        let archive = try #require(await model.export())
        let attributes = try FileManager.default.attributesOfItem(atPath: archive.url.path)
        let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
        #expect(permissions.int16Value == 0o600, "the archive is group or world readable")
        #expect(
            try archive.url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == false
        )

        let written = try Data(contentsOf: archive.url)
        let decoded = try JSONDecoder().decode(GeneratedAPI.DiagnosticsBundle.self, from: written)
        #expect(decoded.manifest.files.map(\.path) == ["runtime.json"])
    }

    @Test func aLinkPlantedAtTheExactDestinationIsRefusedAndItsVictimUntouched() async throws {
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let victim = directory.appendingPathComponent("victim.txt")
        try Data("original".utf8).write(to: victim)

        // The link sits at the name this export is about to use.
        let destination = directory.appendingPathComponent("bundle.json")
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: victim)

        let service = Service(catalogue: Self.catalogue(), bundle: Self.bundle(optional: []))
        let model = Self.model(
            service: service,
            writer: Self.fixedWriter(directory: directory, name: "bundle.json")
        )
        await model.load()

        #expect(await model.export() == nil, "the export wrote through a planted link")
        #expect(model.failure == "DIAGNOSTICS_DESTINATION_EXISTS")
        #expect(try Data(contentsOf: victim) == Data("original".utf8))
        #expect(
            try destination.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true,
            "the link was replaced rather than refused"
        )
    }

    @Test func aBundleWhoseManifestDisagreesWithItsFilesIsNeverWritten() async throws {
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        var tampered = Self.bundle(optional: [])
        tampered.files = [
            GeneratedAPI.DiagnosticsFile(
                path: "runtime.json",
                sensitivity: .operational,
                // The manifest still describes `{}`; this is not it.
                content: "{\"data_dir\":\"/Users/owner/private\"}"
            )
        ]
        let service = Service(catalogue: Self.catalogue(), bundle: tampered)
        let model = Self.model(
            service: service,
            writer: Self.fixedWriter(directory: directory, name: "bundle.json")
        )
        await model.load()

        #expect(await model.export() == nil)
        #expect(model.failure == "DIAGNOSTICS_MANIFEST_MISMATCH")
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty,
            "a rejected bundle left a file behind"
        )
    }

    @Test func aMislabelledSensitivityIsCaughtBeforeAnythingIsWritten() async throws {
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        var tampered = Self.bundle(optional: [])
        tampered.files = [
            GeneratedAPI.DiagnosticsFile(
                path: "runtime.json",
                // The manifest calls this operational.
                sensitivity: .identifying,
                content: "{}"
            )
        ]
        let service = Service(catalogue: Self.catalogue(), bundle: tampered)
        let model = Self.model(
            service: service,
            writer: Self.fixedWriter(directory: directory, name: "bundle.json")
        )
        await model.load()

        #expect(await model.export() == nil)
        #expect(model.failure == "DIAGNOSTICS_MANIFEST_MISMATCH")
    }

    @Test func anInjectedDestinationNameMustBeOneFlatJsonBasename() async throws {
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        for name in [
            "../escape.json",
            "sub/dir.json",
            "bundle.txt",
            "",
            ".json",
            "Bundle.json",
            "bundle.json.json.json.json.json.json.json.json.json.json.json.json.json",
        ] {
            let service = Service(catalogue: Self.catalogue(), bundle: Self.bundle(optional: []))
            let model = Self.model(
                service: service,
                writer: Self.fixedWriter(directory: directory, name: name)
            )
            await model.load()
            #expect(await model.export() == nil, "\(name) was accepted as a destination")
            #expect(model.failure == "DIAGNOSTICS_DESTINATION_INVALID")
        }
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty,
            "a refused name left a file behind"
        )

        // The shipping default satisfies the same rule.
        let service = Service(catalogue: Self.catalogue(), bundle: Self.bundle(optional: []))
        let model = Self.model(
            service: service,
            writer: DiagnosticsArchiveWriter(directory: directory)
        )
        await model.load()
        let archive = try #require(await model.export())
        defer { try? FileManager.default.removeItem(at: archive.url) }
        #expect(archive.url.lastPathComponent.hasSuffix(".json"))
    }

    @Test func twoCopiesOfOneFileCannotStandInForTwoManifestEntries() async throws {
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        var tampered = Self.bundle(optional: [])
        // Replace a missing described file with a duplicate so equal counts cannot conceal a manifest mismatch.
        tampered.manifest.files.append(
            GeneratedAPI.DiagnosticsManifestEntry(
                path: "host.json",
                sensitivity: .operational,
                description: "Host facts.",
                bytes: 2,
                sha256: Self.digest("{}")
            )
        )
        tampered.files.append(tampered.files[0])

        let service = Service(catalogue: Self.catalogue(), bundle: tampered)
        let model = Self.model(
            service: service,
            writer: Self.fixedWriter(directory: directory, name: "bundle.json")
        )
        await model.load()

        #expect(await model.export() == nil)
        #expect(model.failure == "DIAGNOSTICS_MANIFEST_MISMATCH")
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test func anInterruptedWriteIsResumedRatherThanFailed() async throws {
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // Alternate EINTR with one-byte writes to require both retry and forward progress.
        let io = ScriptedFileIO(behaviour: .interruptAlternately)
        let service = Service(catalogue: Self.catalogue(), bundle: Self.bundle(optional: []))
        let model = Self.model(
            service: service,
            writer: DiagnosticsArchiveWriter(
                directory: directory,
                nextName: { "bundle.json" },
                fileIO: io
            )
        )
        await model.load()

        let archive = try #require(await model.export())
        defer { try? FileManager.default.removeItem(at: archive.url) }
        #expect(io.interruptions > 0, "the retry path was never exercised")
        let written = try Data(contentsOf: archive.url)
        let decoded = try JSONDecoder().decode(GeneratedAPI.DiagnosticsBundle.self, from: written)
        #expect(decoded.manifest.files.map(\.path) == ["runtime.json"])
    }

    @Test func aFailedWriteLeavesNothingPartialBehind() async throws {
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let service = Service(catalogue: Self.catalogue(), bundle: Self.bundle(optional: []))
        let model = Self.model(
            service: service,
            writer: DiagnosticsArchiveWriter(
                directory: directory,
                nextName: { "bundle.json" },
                fileIO: ScriptedFileIO(behaviour: .failAfterFirstByte)
            )
        )
        await model.load()

        #expect(await model.export() == nil)
        #expect(model.failure == "DIAGNOSTICS_WRITE_FAILED")
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty,
            "a half-written bundle was left at the destination"
        )

        // Remove failed output so the same destination can be used on retry.
        let retry = Self.model(
            service: Service(catalogue: Self.catalogue(), bundle: Self.bundle(optional: [])),
            writer: Self.fixedWriter(directory: directory, name: "bundle.json")
        )
        await retry.load()
        let archive = try #require(await retry.export())
        defer { try? FileManager.default.removeItem(at: archive.url) }
    }

    @Test func aFailedSyncIsAFailedExport() async throws {
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let service = Service(catalogue: Self.catalogue(), bundle: Self.bundle(optional: []))
        let model = Self.model(
            service: service,
            writer: DiagnosticsArchiveWriter(
                directory: directory,
                nextName: { "bundle.json" },
                fileIO: ScriptedFileIO(behaviour: .failSync)
            )
        )
        await model.load()

        #expect(
            await model.export() == nil,
            "an archive that never reached the disk was offered to the owner"
        )
        #expect(model.failure == "DIAGNOSTICS_WRITE_FAILED")
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test func aFailedExportSurfacesTheRuntimeReasonAndKeepsNoFile() async {
        let service = Service(catalogue: Self.catalogue(), bundle: Self.bundle(optional: []))
        service.bundleResult = .failure(
            APIError(.local(message: "not allowed"), statusCode: 403, code: "ROLE_FORBIDDEN")
        )
        let model = Self.model(service: service)
        await model.load()

        let archive = await model.export()
        #expect(archive == nil)
        // The stable code, not the server's prose.
        #expect(model.failure == "ROLE_FORBIDDEN")
    }
}
