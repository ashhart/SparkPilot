import Foundation
import Security

let query: [CFString: Any] = [
    kSecClass: kSecClassKey,
    kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
    kSecAttrTokenID: kSecAttrTokenIDSecureEnclave,
    kSecAttrApplicationTag: Data("spark-readiness-absent-\(UUID().uuidString)".utf8),
    kSecReturnRef: true,
]
var item: CFTypeRef?
let status = SecItemCopyMatching(query as CFDictionary, &item)
print("Read-only Secure Enclave lookup: \(status)")
exit(status == errSecItemNotFound ? 0 : 1)
