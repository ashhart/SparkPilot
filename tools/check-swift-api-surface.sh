#!/usr/bin/env bash
# Reject unpinned transport access while proving that supported shipping calls still compile.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

failures=0
pass() { printf '  ok    %s\n' "$*"; }
fail() { printf '  FAIL  %s\n' "$*" >&2; failures=$((failures + 1)); }

mkdir -p "$WORK/probe/Sources/Probe"
cat > "$WORK/probe/Package.swift" <<EOF
// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "Probe",
    platforms: [.iOS(.v26), .macOS(.v26)],
    dependencies: [
        .package(path: "$ROOT/apple/Packages/SparkAPI"),
        .package(path: "$ROOT/apple/Packages/SparkTransport"),
        .package(path: "$ROOT/apple/Packages/SparkBootstrap"),
    ],
    targets: [
        .target(
            name: "Probe",
            dependencies: ["SparkAPI", "SparkTransport", "SparkBootstrap"]
        )
    ]
)
EOF

preamble() {
  cat <<'EOF'
import Foundation
import SparkAPI
import SparkBootstrap
import SparkSecurity
import SparkTransport

struct ForgedTransport: PinnedHTTPTransport {
    var pin: String { String(repeating: "a", count: 64) }
    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        (Data(), HTTPURLResponse())
    }
}
EOF
}

build_probe() {
  ( cd "$WORK/probe" && swift build 2>&1 )
}

# --- Each of these must NOT compile ------------------------------------------

must_not_compile() {
  local description="$1" expression="$2"
  {
    preamble
    printf 'func probe() throws {\n    %s\n}\n' "$expression"
  } > "$WORK/probe/Sources/Probe/Probe.swift"

  if build_probe > "$WORK/out" 2>&1; then
    fail "$description — it compiled, so a shipping client can do this"
  else
    pass "$description"
  fi
}

printf '\n== seams that must be closed to a normal import\n'

must_not_compile "a forged transport cannot be given to SparkAPIClient" \
  '_ = SparkAPIClient(transport: ForgedTransport())'
must_not_compile "a forged transport cannot be given to PairingClient" \
  '_ = PairingClient(transport: ForgedTransport())'
must_not_compile "a session cannot be built from an arbitrary trust policy" \
  '_ = PinnedSession.session(policy: PinnedTrustPolicy(fingerprint: "a"))'
must_not_compile "a pinned session cannot be built directly" \
  '_ = PinnedSession.pinned(to: "a")'
must_not_compile "a non-pinning trust policy mode cannot be chosen" \
  '_ = PinnedTrustPolicy(mode: .publicCertificateAuthority)'
must_not_compile "a trust delegate cannot be built from an arbitrary policy" \
  '_ = PinnedSessionDelegate(policy: PinnedTrustPolicy(fingerprint: "a"))'
must_not_compile "URLProtocol cannot be injected into the transport" \
  '_ = try URLSessionPinnedTransport(pin: "a", interceptingWith: [])'
must_not_compile "URLProtocol cannot be injected into ChatClient" \
  '_ = try ChatClient(baseURL: URL(string: "https://s")!, pin: "a", interceptingWith: [])'
must_not_compile "URLProtocol cannot be injected into BuildClient" \
  '_ = try BuildClient(baseURL: URL(string: "https://s")!, pin: "a", interceptingWith: [])'
must_not_compile "URLProtocol cannot be injected into the release source" \
  '_ = HTTPSReleaseSource(manifestURL: URL(string: "https://s")!, interceptingWith: [])'
must_not_compile "a transport factory cannot be substituted into pairing" \
  '_ = FirstOwnerPairing(signer: SoftwareSigner(), deviceID: UUID(), deviceName: "d", platform: "ios", testTransportFactory: { _ in ForgedTransport() })'

# --- And the supported surface must still compile -----------------------------

printf '\n== the shipping surface is still reachable\n'
{
  preamble
  cat <<'EOF'
func supported(pin: String, signer: any RequestSigning) throws {
    let client = try SparkAPIClient.pinned(to: pin, signer: signer)
    _ = RouteProbe(pin: pin, using: client)
    _ = try RouteProbe(pin: pin, signer: signer)
    _ = try PairingClient(pin: pin)
    _ = try URLSessionPinnedTransport(pin: pin)
    _ = try ChatClient(baseURL: URL(string: "https://spark.local:7443")!, pin: pin, signer: signer)
    _ = try BuildClient(baseURL: URL(string: "https://spark.local:7443")!, pin: pin, signer: signer)
    _ = RelayClient()
    _ = PinnedTrustPolicy(fingerprint: pin)
    _ = HTTPSReleaseSource(manifestURL: URL(string: "https://releases.invalid/m.json")!)
}

@MainActor
func supportedPairing(signer: any SendableDeviceSigning) {
    _ = FirstOwnerPairing(
        signer: signer,
        deviceID: UUID(),
        deviceName: "iPhone",
        platform: "ios",
        userPresenceAuthorizer: SystemUserPresenceAuthorizer()
    )
}
EOF
} > "$WORK/probe/Sources/Probe/Probe.swift"

if build_probe > "$WORK/out" 2>&1; then
  pass "every supported call site compiles"
else
  fail "the shipping surface does not compile: $(cat "$WORK/out")"
fi

if [ "$failures" -ne 0 ]; then
  printf '\n%d API-surface check(s) failed\n' "$failures" >&2
  exit 1
fi
printf '\nswift API surface ok: no shipping path reaches a Spark unpinned\n'
