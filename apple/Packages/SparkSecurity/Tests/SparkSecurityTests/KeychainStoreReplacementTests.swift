import Foundation
import Security
import Testing

@testable import SparkSecurity

private final class KeychainReplacementProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Data?
    private var updateCount = 0
    private var addCount = 0
    private let updateStatus: OSStatus
    private let addStatus: OSStatus

    init(stored: Data?, updateStatus: OSStatus, addStatus: OSStatus) {
        self.stored = stored
        self.updateStatus = updateStatus
        self.addStatus = addStatus
    }

    func update(_: CFDictionary, _ attributes: CFDictionary) -> OSStatus {
        lock.withLock {
            updateCount += 1
            if updateStatus == errSecSuccess {
                stored = (attributes as NSDictionary)[kSecValueData] as? Data
            }
        }
        return updateStatus
    }

    func add(_ item: CFDictionary) -> OSStatus {
        lock.withLock {
            addCount += 1
            if addStatus == errSecSuccess {
                stored = (item as NSDictionary)[kSecValueData] as? Data
            }
        }
        return addStatus
    }

    func snapshot() -> (stored: Data?, updateCount: Int, addCount: Int) {
        lock.withLock { (stored, updateCount, addCount) }
    }
}

@Test func aFailedReplacementKeepsThePriorKeychainRecord() throws {
    let prior = Data("prior-credential".utf8)
    let probe = KeychainReplacementProbe(
        stored: prior,
        updateStatus: errSecInteractionNotAllowed,
        addStatus: errSecInteractionNotAllowed
    )
    let store = KeychainStore(
        updateItem: probe.update,
        addItem: probe.add
    )

    #expect(throws: KeychainError.unexpectedStatus(errSecInteractionNotAllowed)) {
        try store.set(Data("replacement".utf8), service: "service", account: "account")
    }
    let result = probe.snapshot()
    #expect(result.stored == prior, "a failed replacement must not delete the prior credential")
    #expect(result.updateCount == 1, "replacement must use the atomic update primitive")
    #expect(result.addCount == 0, "an update failure must not fall through to add")
}

@Test func aMissingRecordFallsBackToOneAdd() throws {
    let replacement = Data("replacement".utf8)
    let probe = KeychainReplacementProbe(
        stored: nil,
        updateStatus: errSecItemNotFound,
        addStatus: errSecSuccess
    )
    let store = KeychainStore(updateItem: probe.update, addItem: probe.add)

    try store.set(replacement, service: "service", account: "account")

    let result = probe.snapshot()
    #expect(result.stored == replacement)
    #expect(result.updateCount == 1)
    #expect(result.addCount == 1)
}
