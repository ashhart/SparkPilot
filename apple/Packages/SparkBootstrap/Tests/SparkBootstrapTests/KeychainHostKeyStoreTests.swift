import Foundation
import SparkSecurity
import Testing

@testable import SparkBootstrap

/// Keep persisted SSH host trust scoped by both host and credential-service namespace.

private let fingerprint = SSHHostKeyFingerprint(
    keyType: "ssh-ed25519",
    publicKeyBlob: Data(repeating: 0x2a, count: 32)
)
private let otherFingerprint = SSHHostKeyFingerprint(
    keyType: "ssh-ed25519",
    publicKeyBlob: Data(repeating: 0x7f, count: 32)
)

@Test func aConfirmedHostKeySurvivesRelaunch() throws {
    let backing = InMemoryStore()
    try KeychainHostKeyStore(store: backing).remember(fingerprint, forHost: "spark-a1b2.local")

    // A fresh store over the same backing, as the next launch would build.
    let reloaded = try KeychainHostKeyStore(store: backing)
        .fingerprint(forHost: "spark-a1b2.local")
    #expect(reloaded == fingerprint)
    #expect(reloaded?.keyType == "ssh-ed25519")
    #expect(reloaded?.displayString.hasPrefix("SHA256:") == true)
}

@Test func hostNamesAreMatchedWithoutRegardToCaseOrSurroundingSpace() throws {
    // Use one host-key record for case variants of the same hostname.
    let store = KeychainHostKeyStore(store: InMemoryStore())
    try store.remember(fingerprint, forHost: "Spark-A1B2.local")

    #expect(try store.fingerprint(forHost: "spark-a1b2.local") == fingerprint)
    #expect(try store.fingerprint(forHost: "  SPARK-A1B2.LOCAL  ") == fingerprint)
}

@Test func aDifferentHostIsADifferentRecord() throws {
    // Never reuse one host's confirmed key as trust for another host.
    let store = KeychainHostKeyStore(store: InMemoryStore())
    try store.remember(fingerprint, forHost: "spark-a1b2.local")

    #expect(try store.fingerprint(forHost: "spark-c3d4.local") == nil)
    try store.remember(otherFingerprint, forHost: "spark-c3d4.local")
    #expect(try store.fingerprint(forHost: "spark-a1b2.local") == fingerprint)
    #expect(try store.fingerprint(forHost: "spark-c3d4.local") == otherFingerprint)
}

@Test func forgettingOneHostLeavesTheOthers() throws {
    // Allow explicit removal of one changed host key without clearing other hosts.
    let store = KeychainHostKeyStore(store: InMemoryStore())
    try store.remember(fingerprint, forHost: "spark-a1b2.local")
    try store.remember(otherFingerprint, forHost: "spark-c3d4.local")

    try store.forget(host: "SPARK-A1B2.local")
    #expect(try store.fingerprint(forHost: "spark-a1b2.local") == nil)
    #expect(try store.fingerprint(forHost: "spark-c3d4.local") == otherFingerprint)
}

@Test func forgettingAHostThatWasNeverKnownIsNotAnError() throws {
    let store = KeychainHostKeyStore(store: InMemoryStore())
    #expect(throws: Never.self) { try store.forget(host: "spark-nobody.local") }
}

@Test func hostKeysAreNotStoredWhereTheDeviceKeyOrNodeTrustLive() throws {
    // Separate Keychain service namespaces for distinct credential types.
    #expect(KeychainHostKeyStore.service != SoftwareSigner.service)
    #expect(KeychainHostKeyStore.service != NodeTrustStore.service)
    #expect(KeychainHostKeyStore.service != NodeTrustStore.stagingService)

    let backing = InMemoryStore()
    try KeychainHostKeyStore(store: backing).remember(fingerprint, forHost: "spark-a1b2.local")

    #expect(try backing.accounts(service: SoftwareSigner.service).isEmpty)
    #expect(try backing.accounts(service: NodeTrustStore.service).isEmpty)
    #expect(try backing.accounts(service: KeychainHostKeyStore.service) == ["spark-a1b2.local"])
}

@Test func aStoredRecordThatCannotBeReadIsAnErrorRatherThanAnAbsence() throws {
    // Treat corrupt host-key storage as an error rather than a first-sighting trust prompt.
    let backing = InMemoryStore()
    try backing.set(
        Data("not json".utf8),
        service: KeychainHostKeyStore.service,
        account: "spark-a1b2.local"
    )
    #expect(throws: (any Error).self) {
        _ = try KeychainHostKeyStore(store: backing).fingerprint(forHost: "spark-a1b2.local")
    }
}
