import CryptoKit
import Foundation
import SparkSecurity

extension ReleaseTrustRoot {
    func validateDelegation(keysDocument: JSONValue?) throws {
        guard schema == 2 else { return }
        func invalid(_ reason: String) -> ReleaseTrustError { .invalidDelegation(reason) }
        guard let fields = delegationDocument?.objectValue,
            Set(fields.keys) == ["version", "not_before", "not_after", "signature"],
            let version = fields["version"]?.integerValue,
            let minimum = minimumDelegationVersion, minimum > 0, version >= minimum,
            !rootKeys.isEmpty,
            let beforeText = fields["not_before"]?.stringValue,
            let afterText = fields["not_after"]?.stringValue,
            let before = RFC3339.date(from: beforeText), let after = RFC3339.date(from: afterText),
            before < after, let rawSignature = fields["signature"],
            Set(rawSignature.objectValue?.keys.map { $0 } ?? []) == [
                "key_id", "algorithm", "value",
            ]
        else { throw invalid("invalid certificate, version or window") }
        let signature: ManifestSignature
        do { signature = try ManifestSignature(json: rawSignature) } catch {
            throw invalid("invalid certificate signature")
        }
        guard let root = rootKeys.first(where: { $0.keyID == signature.keyID }) else {
            throw ReleaseTrustError.unknownKeyID(signature.keyID)
        }
        var seen: Set<String> = []
        for key in rootKeys + keys {
            guard seen.insert(key.keyID).inserted else {
                throw ReleaseTrustError.duplicateKeyID(key.keyID)
            }
        }
        guard rootKeys.allSatisfy({ $0.purposes == ["release-delegation"] }),
            before >= root.notBefore, after <= root.notAfter
        else {
            throw invalid("certificate exceeds offline authority")
        }
        for key in keys {
            guard key.notBefore >= before, key.notAfter <= after,
                Set(key.channels).isSubset(of: Set(root.channels)),
                !key.purposes.contains("release-delegation"),
                !(key.purposes.contains(Self.cataloguePurpose)
                    && (key.purposes.contains(Self.manifestPurpose)
                        || key.purposes.contains(Self.packagePurpose))),
                !rootKeys.contains(where: {
                    $0.publicKey.lowercased() == key.publicKey.lowercased()
                })
            else { throw invalid("online key exceeds scope or reuses another authority") }
        }
        guard let keysDocument, let signatureBytes = Base64URL.decode(signature.value) else {
            throw invalid("missing online keys or signature")
        }
        let payload = JSONValue.object([
            "schema": .integer(2), "keys": keysDocument,
            "version": .integer(version), "not_before": .string(beforeText),
            "not_after": .string(afterText),
        ])
        var canonical = Data("SPARK-RELEASE-DELEGATION-V2\n".utf8)
        canonical.append(try payload.canonicalBytes())
        guard try root.verifyingKey().isValidSignature(signatureBytes, for: canonical) else {
            throw ReleaseTrustError.signatureInvalid(root.keyID)
        }
    }

    func authorizeChannel(_ channel: String, at moment: Date) throws {
        if schema == 1 {
            guard Self.directTrustChannels.contains(channel) else {
                throw ReleaseTrustError.delegationRequired(channel)
            }
            return
        }
        guard schema == 2, let fields = delegationDocument?.objectValue,
            let keyID = fields["signature"]?.objectValue?["key_id"]?.stringValue,
            let root = rootKeys.first(where: { $0.keyID == keyID }),
            let beforeText = fields["not_before"]?.stringValue,
            let afterText = fields["not_after"]?.stringValue,
            let before = RFC3339.date(from: beforeText), let after = RFC3339.date(from: afterText),
            moment >= before, moment < after
        else {
            throw ReleaseTrustError.invalidDelegation("certificate expired or not yet valid")
        }
        try root.assertUsable(
            at: moment,
            channel: channel,
            purpose: "release-delegation",
            needed: "delegate online release keys"
        )
    }
}
