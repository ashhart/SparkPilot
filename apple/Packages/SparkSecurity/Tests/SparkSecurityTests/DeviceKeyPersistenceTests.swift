import CryptoKit
import Foundation
import Testing

@testable import SparkSecurity

/// Reuse enrolled signing identity across relaunch rather than creating a new key or falling back unsigned.

@Test func aSoftwareKeyIsTheSameKeyOnTheNextLaunch() throws {
    let store = InMemoryStore()
    let tag = DeviceKeyFactory.defaultApplicationTag

    let first = try SoftwareSigner(applicationTag: tag, store: store)
    let second = try SoftwareSigner(applicationTag: tag, store: store)

    #expect(first.publicKeySPKI == second.publicKeySPKI, "relaunch must reload, not regenerate")

    // Verify signatures across instances to prove they share the same persisted private key.
    let payload = Data("SPARK1 canonical request".utf8)
    let signature = try first.sign(payload)
    let publicKey = try P256.Signing.PublicKey(derRepresentation: second.publicKeySPKI)
    let parsed = try P256.Signing.ECDSASignature(rawRepresentation: signature)
    #expect(publicKey.isValidSignature(parsed, for: payload))
}

@Test func constructingASignerTwiceDoesNotThrow() throws {
    // Allow a second signer instance to reuse the existing Keychain item.
    let store = InMemoryStore()
    let tag = DeviceKeyFactory.defaultApplicationTag
    _ = try SoftwareSigner(applicationTag: tag, store: store)
    _ = try SoftwareSigner(applicationTag: tag, store: store)
    _ = try SoftwareSigner(applicationTag: tag, store: store)
}

@Test func differentApplicationTagsAreDifferentKeys() throws {
    let store = InMemoryStore()
    let one = try SoftwareSigner(applicationTag: Data("app.spark.device-key".utf8), store: store)
    let two = try SoftwareSigner(applicationTag: Data("app.spark.other-key".utf8), store: store)
    #expect(one.publicKeySPKI != two.publicKeySPKI)
}

@Test func destroyingTheKeyMakesTheNextLaunchANewDevice() throws {
    let store = InMemoryStore()
    let tag = DeviceKeyFactory.defaultApplicationTag
    let before = try SoftwareSigner(applicationTag: tag, store: store)

    try DeviceKeyFactory.destroy(applicationTag: tag, store: store)

    let after = try SoftwareSigner(applicationTag: tag, store: store)
    #expect(before.publicKeySPKI != after.publicKeySPKI, "unpairing must forget the key")
}

@Test func theFactoryReturnsASignerThatCanCrossAnIsolationBoundary() throws {
    // Require both concrete signer types to support safe actor handoff.
    let store = InMemoryStore()
    let signer: any SendableDeviceSigning = try DeviceKeyFactory.makeSigner(store: store)
    #expect(!signer.publicKeySPKI.isEmpty)

    let payload = Data("crosses an actor boundary".utf8)
    #expect(try !signer.sign(payload).isEmpty)
}

@Test func anEphemeralSignerTouchesNoStore() throws {
    let store = InMemoryStore()
    _ = SoftwareSigner()
    #expect(try store.data(service: SoftwareSigner.service, account: "anything") == nil)
}

@Test func aSignatureIsRawRSAndSVerifiableByAnyStandardVerifier() throws {
    let signer = try SoftwareSigner(applicationTag: Data("t".utf8), store: InMemoryStore())
    let payload = Data("SPARK1\nGET\n/api/v1/status".utf8)
    let signature = try signer.sign(payload)

    // Require 64 raw signature bytes accepted by the runtime's P-256 parser.
    #expect(signature.count == 64)
    let publicKey = try P256.Signing.PublicKey(derRepresentation: signer.publicKeySPKI)
    #expect(
        publicKey.isValidSignature(
            try P256.Signing.ECDSASignature(rawRepresentation: signature),
            for: payload
        )
    )
}

// MARK: - The key must not be replaceable by a race

/// A store whose `add` always reports a collision, as if another launch won.
private final class ContendedStore: SecureStore, @unchecked Sendable {
    private let inner = InMemoryStore()
    private let lock = NSLock()
    private var winner: Data?

    /// What the racing writer stored.
    init(winner: Data?) { self.winner = winner }

    func set(_ data: Data, service: String, account: String) throws {
        try inner.set(data, service: service, account: account)
    }

    func add(_ data: Data, service: String, account: String) throws {
        // Recover an existing paired key when another writer wins the read-then-insert race.
        lock.lock()
        defer { lock.unlock() }
        if let winner {
            try inner.set(winner, service: service, account: account)
            self.winner = nil
        }
        throw KeychainError.alreadyExists
    }

    func data(service: String, account: String) throws -> Data? {
        try inner.data(service: service, account: account)
    }

    func delete(service: String, account: String) throws {
        try inner.delete(service: service, account: account)
    }

    func accounts(service: String) throws -> [String] {
        try inner.accounts(service: service)
    }
}

@Test func aLosingRacerAdoptsTheStoredKeyRatherThanReplacingIt() throws {
    // Preserve the first stored key when concurrent signer creation races.
    let established = P256.Signing.PrivateKey()
    let store = ContendedStore(winner: established.derRepresentation)

    let signer = try SoftwareSigner(
        applicationTag: DeviceKeyFactory.defaultApplicationTag,
        store: store
    )
    #expect(signer.publicKeySPKI == established.publicKey.derRepresentation)

    // The persisted key must remain the established identity after a creation race.
    let stored = try #require(
        try store.data(
            service: SoftwareSigner.service,
            account: String(decoding: DeviceKeyFactory.defaultApplicationTag, as: UTF8.self)
        )
    )
    #expect(stored == established.derRepresentation)
}

/// Simulate a storage collision followed by an inconsistent missing value.
private final class InconsistentStore: SecureStore, @unchecked Sendable {
    func set(_ data: Data, service: String, account: String) throws {}
    func add(_ data: Data, service: String, account: String) throws {
        throw KeychainError.alreadyExists
    }
    func data(service: String, account: String) throws -> Data? { nil }
    func delete(service: String, account: String) throws {}
    func accounts(service: String) throws -> [String] { [] }
}

@Test func anInconsistentStoreFailsRatherThanOverwriting() throws {
    // Fail after an unreadable collision instead of repeatedly overwriting a potentially valid key.
    #expect(throws: DeviceKeyError.self) {
        _ = try SoftwareSigner(
            applicationTag: DeviceKeyFactory.defaultApplicationTag,
            store: InconsistentStore()
        )
    }
}

@Test func theStoreDistinguishesAddFromSet() throws {
    let store = InMemoryStore()
    try store.add(Data([1]), service: "s", account: "a")
    #expect(throws: KeychainError.alreadyExists) {
        try store.add(Data([2]), service: "s", account: "a")
    }
    #expect(try store.data(service: "s", account: "a") == Data([1]))

    // `set` is the deliberate replace, and stays that way.
    try store.set(Data([2]), service: "s", account: "a")
    #expect(try store.data(service: "s", account: "a") == Data([2]))
}
