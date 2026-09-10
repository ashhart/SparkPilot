# Security

SparkPilot is a private-compute product. The security model is load-bearing,
not cosmetic: signed device requests, replay protection, role checks, and
audit are mandatory on every route, local or remote.

## Reporting a vulnerability

Do not open a public issue for a security defect. Report to
[feedback@sparkpilot.dev](mailto:feedback@sparkpilot.dev) with the subject
"Security report". Include:

- The affected component (`sparkd`, `spark-privd`, `spark-installer`,
  `spark-updater`, Apple packages, recipes, packaging).
- Reproduction steps, including the route and roles involved.
- Version/digest information from `docs/build/source-lock.json`.

## Trust boundaries

```text
Apple UI process
  -> Keychain/Secure Enclave
  -> local or remote network
  -> sparkd authentication boundary
  -> spark-privd Unix socket boundary
  -> model container boundary
  -> project container boundary
  -> optional second Spark cluster boundary
```

## Required controls

- Signed requests and replay protection on every route.
- TLS with identity pinning on local and Tailscale routes; no unauthenticated model endpoint.
- No arbitrary shell operation in the privileged API.
- Pinned OCI image digests; signed catalogue and recipes.
- `trust_remote_code=false` by default; read-only model mounts.
- No host Docker socket in project or model containers.
- Least-privilege systemd restrictions.
- Explicit user approval for destructive/admin actions.
- Audit trail with tamper-evident chaining.
- Secret redaction in logs and diagnostic bundles.

## Responsible handling

- Real credentials must never be committed; security tests use synthetic examples.
- Diagnostics exclude prompts, keys, and tokens by default.
- Tailscale is connectivity only; final authorisation stays with
  Spark device identity and roles.
