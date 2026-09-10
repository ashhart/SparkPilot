import Foundation

/// Allow only fixed bootstrap commands with UUID, digest, size and filename parameters validated by construction (§11.4).
public enum BootstrapCommand: Sendable, Equatable, Hashable {
    /// Survey without elevation, writes or caller parameters, reporting unobservable facts as unknown.
    case surveyHost
    /// `install -d -m 0700 /tmp/spark-bootstrap/<operation>`
    case prepareWorkDirectory
    /// Transfer only four known artifacts on stdin into a UUID-derived operation directory.
    case receiveFile(RemoteFile)
    /// Check transferred package bytes against the digest in the verified manifest.
    case verifyDigest
    /// Verify package integrity with stock OpenSSL after Apple-side trust verification, and additionally use the node's installed root on upgrades.
    case verifyDetachedSignature
    /// Reverify with the installed node trust root when present, explicitly reporting a first-install skip.
    case verifyAgainstInstalledTrustRoot
    /// Install the verified local package with dpkg while optional recommendations remain outside the offline configuration gate.
    case installPackage
    /// Attempt recommended tool installation without making an offline Spark lose its configured runtime.
    case installRecommendedTools
    /// `systemctl enable --now` the helper, then the daemon.
    case enablePrivilegedHelper
    case enableRuntime
    /// Mint the single-use first-owner invitation and print it as JSON.
    case bootstrapOwner
    /// Remove the package, its signature, and the key from `/tmp`.
    case cleanUp

    /// Restrict transfers to a closed set of installer artifacts rather than arbitrary paths.
    public enum RemoteFile: String, Sendable, Equatable, Hashable, CaseIterable {
        /// The `.deb` itself.
        case package
        /// Its detached Ed25519 signature.
        case signature
        /// Provide the public release key as PEM for OpenSSL verification before dpkg.
        case publicKey
        /// Retain the signed manifest for verification against a previously installed node trust root.
        case manifest

        func path(_ parameters: Parameters) -> String {
            switch self {
            case .package: return parameters.packagePath
            case .signature: return parameters.signaturePath
            case .publicKey: return parameters.publicKeyPath
            case .manifest: return parameters.manifestPath
            }
        }
    }

    /// Keep file-transfer stdin separate from administrator-password stdin.
    public var requiresElevation: Bool {
        switch self {
        case .surveyHost, .prepareWorkDirectory, .receiveFile, .verifyDigest,
            .verifyDetachedSignature, .cleanUp:
            return false
        case .verifyAgainstInstalledTrustRoot, .installPackage, .installRecommendedTools,
            .enablePrivilegedHelper, .enableRuntime, .bootstrapOwner:
            return true
        }
    }

    /// A short description for progress and audit. Never contains a password.
    public var summary: String {
        switch self {
        case .surveyHost: return String(localized: "Checking what is already on this Spark")
        case .prepareWorkDirectory:
            return String(localized: "Preparing a private working directory")
        case .receiveFile(let file):
            switch file {
            case .package: return String(localized: "Copying Spark Runtime to the Spark")
            case .signature: return String(localized: "Copying the package signature")
            case .publicKey: return String(localized: "Copying the release key")
            case .manifest: return String(localized: "Copying the release manifest")
            }
        case .verifyDigest: return String(localized: "Checking the package digest")
        case .verifyDetachedSignature: return String(localized: "Checking the package signature")
        case .verifyAgainstInstalledTrustRoot:
            return String(localized: "Re-checking against this Spark's trust root")
        case .installPackage: return String(localized: "Installing Spark Runtime")
        case .installRecommendedTools:
            return String(localized: "Installing recommended network tools")
        case .enablePrivilegedHelper: return String(localized: "Starting the privileged helper")
        case .enableRuntime: return String(localized: "Starting Spark Runtime")
        case .bootstrapOwner: return String(localized: "Preparing first-owner pairing")
        case .cleanUp: return String(localized: "Removing temporary files")
        }
    }
}

extension BootstrapCommand {
    /// Validate every command parameter at construction so unchecked strings cannot reach execution.
    public struct Parameters: Sendable, Equatable {
        public let operationID: UUID
        public let artifactName: String
        public let sha256: String
        public let size: Int64

        public init(operationID: UUID, artifactName: String, sha256: String, size: Int64) throws {
            guard BootstrapCommand.isSafeArtifactName(artifactName) else {
                throw BootstrapCommandError.unsafeArtifactName(artifactName)
            }
            guard isSHA256Hex(sha256) else {
                throw BootstrapCommandError.unsafeDigest(sha256)
            }
            guard size > 0 else {
                throw BootstrapCommandError.unsafeSize(size)
            }
            self.operationID = operationID
            self.artifactName = artifactName
            self.sha256 = sha256
            self.size = size
        }

        /// Derive the operation directory solely from a UUID generated by this device.
        public var workDirectory: String {
            "/tmp/spark-bootstrap/\(operationID.uuidString.lowercased())"
        }
        public var packagePath: String { "\(workDirectory)/\(artifactName)" }
        public var signaturePath: String { "\(packagePath).sig" }
        public var publicKeyPath: String { "\(workDirectory)/release.pub.pem" }
        public var manifestPath: String { "\(workDirectory)/manifest.json" }
    }

    /// Accept only bounded Debian-style artifact names without spaces, quotes, slashes, leading dots or shell metacharacters.
    public static func isSafeArtifactName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 128 else { return false }
        guard name.first != "." else { return false }
        guard name.hasSuffix(".deb") else { return false }
        return name.allSatisfy { character in
            character.isASCII
                && (character.isLetter || character.isNumber
                    || character == "." || character == "-" || character == "_" || character == "+")
        }
    }

    /// Supply sudo credentials only on stdin so passwords never enter command strings, process arguments or logs.
    public func line(_ parameters: Parameters) -> String {
        let work = parameters.workDirectory
        let package = parameters.packagePath
        let signature = parameters.signaturePath
        let publicKey = parameters.publicKeyPath

        switch self {
        case .surveyHost:
            return Self.hostSurveyScript

        case .prepareWorkDirectory:
            return "install -d -m 0700 \(work)"

        case .receiveFile(let file):
            // Write stdin to one known UUID-scoped artifact path, replacing any prior contents.
            return "cat > \(file.path(parameters))"

        case .verifyDigest:
            // Verify the signed manifest's expected digest with sha256sum -c.
            return
                "cd \(work) && printf '%s  %s\\n' \(parameters.sha256) \(parameters.artifactName)"
                + " | sha256sum -c --status"

        case .verifyDetachedSignature:
            return
                "openssl pkeyutl -verify -pubin -inkey \(publicKey)"
                + " -rawin -in \(package) -sigfile \(signature) >/dev/null"

        case .verifyAgainstInstalledTrustRoot:
            // Explicitly report when no installed trust root exists instead of claiming first-install verification against one.
            return
                "if [ -x /usr/lib/spark-runtime/spark-installer ]"
                + " && [ -f /usr/share/spark-runtime/trust/release-keys.json ]; then"
                + " sudo -S -p '' /usr/lib/spark-runtime/spark-installer verify-package"
                + " --package \(package) --signature \(signature)"
                + " --manifest \(parameters.manifestPath)"
                + " --trust-root /usr/share/spark-runtime/trust/release-keys.json;"
                + " else echo spark-bootstrap-no-installed-trust-root; fi"

        case .installPackage:
            return "sudo -S -p '' dpkg -i \(package)"

        case .installRecommendedTools:
            return "sudo -S -p '' apt-get install -y --no-install-recommends iputils-arping"

        case .enablePrivilegedHelper:
            return "sudo -S -p '' systemctl enable --now spark-privd.service"

        case .enableRuntime:
            return "sudo -S -p '' systemctl enable --now sparkd.service"

        case .bootstrapOwner:
            return
                "sudo -S -p '' /usr/lib/spark-runtime/spark-installer bootstrap-owner"
                + " --data-dir /var/lib/spark-runtime"

        case .cleanUp:
            return "rm -rf \(work)"
        }
    }
}

extension BootstrapCommand {
    /// Run the fixed unelevated survey without writes or sourcing host files, emitting bounded key=value facts with explicit unknowns.
    static let hostSurveyScript = """
        printf 'survey=1\\n'
        printf 'os=%s\\n' "$(sed -n 's/^PRETTY_NAME="\\{0,1\\}\\([^"]*\\)"\\{0,1\\}$/\\1/p' /etc/os-release 2>/dev/null | head -n 1)"
        if command -v dpkg-query >/dev/null 2>&1; then
          printf 'runtime_package=%s\\n' "$(dpkg-query -W -f='${Version}' spark-runtime 2>/dev/null || printf absent)"
        else
          printf 'runtime_package=unknown\\n'
        fi
        if command -v dpkg >/dev/null 2>&1; then
          printf 'path_package=%s\\n' "$(dpkg -S /usr/lib/spark-runtime 2>/dev/null | head -n 1 | cut -d: -f1 | grep . || printf none)"
        else
          printf 'path_package=unknown\\n'
        fi
        if command -v systemctl >/dev/null 2>&1; then
          printf 'unit_sparkd=%s\\n' "$(systemctl list-unit-files sparkd.service --no-legend --plain 2>/dev/null | head -n 1 | awk '{print $2}' | grep . || printf absent)"
          printf 'unit_privd=%s\\n' "$(systemctl list-unit-files spark-privd.service --no-legend --plain 2>/dev/null | head -n 1 | awk '{print $2}' | grep . || printf absent)"
          if units=$(systemctl list-units --type=service --state=running --no-legend --plain 2>/dev/null); then
            printf 'services=%s\\n' "$(printf '%s\\n' "$units" | grep -c . )"
          else
            printf 'services=unknown\\n'
          fi
        else
          printf 'unit_sparkd=unknown\\nunit_privd=unknown\\nservices=unknown\\n'
        fi
        printf 'state_dir=%s\\n' "$(test -e /var/lib/spark-runtime && printf present || printf absent)"
        printf 'install_dir=%s\\n' "$(test -e /usr/lib/spark-runtime && printf present || printf absent)"
        printf 'disk=%s\\n' "$(df -Pk / 2>/dev/null | awk 'NR==2 {print $2","$4}')"
        printf 'memory_kb=%s\\n' "$(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null)"
        if sockets=$(ss -H -lnt 2>/dev/null); then
          printf 'listening=%s\\n' "$(printf '%s\\n' "$sockets" | awk '{print $4}' | sed 's/.*://' | grep . | sort -un | head -n 32 | paste -sd, -)"
        else
          printf 'listening=unknown\\n'
        fi
        if containers=$(docker ps --format '{{.Names}} {{.Image}}' 2>/dev/null); then
          printf 'containers=%s\\n' "$(printf '%s\\n' "$containers" | grep -c . )"
          printf '%s\\n' "$containers" | grep . | head -n 16 | sed 's/^/container=/'
        else
          printf 'containers=unknown\\n'
        fi
        for interface in /sys/class/net/*; do
          [ -r "$interface/device/vendor" ] || continue
          [ "$(cat "$interface/device/vendor" 2>/dev/null)" = "0x15b3" ] || continue
          printf 'fabric=%s %s %s\\n' "${interface##*/}" "$(cat "$interface/carrier" 2>/dev/null)" "$(cat "$interface/speed" 2>/dev/null)"
        done
        if [ -d /etc/netplan ]; then
          printf 'netplan=%s\\n' "$(ls -1 /etc/netplan 2>/dev/null | grep -c . )"
        else
          printf 'netplan=absent\\n'
        fi
        """
}

public enum BootstrapCommandError: Error, Equatable, Sendable {
    case unsafeArtifactName(String)
    case unsafeDigest(String)
    case unsafeSize(Int64)
}
