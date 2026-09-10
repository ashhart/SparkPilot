# Contributing

SparkPilot contributions should include focused changes, relevant tests and a clear description of the resulting behavior.
Read the applicable source and contracts before changing a boundary.

## Ground rules

- Compiles for all declared targets; unit tests pass.
- Security-sensitive code has negative tests.
- User-visible state includes loading/error/recovery/accessibility states.
- API/schema changes regenerate contract bindings and pass contract checks.
- No TODO remains in the critical path; no secret is committed.
- No public listener for vLLM; no arbitrary shell in `spark-privd`.
- Never weaken security to make a demo pass.

## Development loop

1. Identify the behavior and its existing tests.
2. Implement one coherent change with regression coverage where needed.
3. Run `just format`, then the checks relevant to the change and `just ci`.
4. Regenerate API bindings when changing contracts.
5. Explain the change and validation in the pull request.

## Dependencies

- Rust 1.94.0 (pinned in `rust-toolchain.toml`) with `clippy` and `rustfmt`.
- cargo-audit 0.22.2. `just audit` installs this exact version under
  `.build/tools` when needed.
- Xcode 26.6 with its bundled swift-format 6.3.0. Apple build and format gates
  require macOS because the packages target Apple SDKs. CI selects that Xcode
  explicitly on the `macos-26` runner. Xcode 27 remains the product target;
  Use the pinned SDK for reproducible builds.
- CPython 3.12.x with the version and artifact hashes in
  `tools/requirements-contracts.txt`.
  The contract environment validates the complete OpenAPI 3.1 document and
  regenerates the transport-neutral Swift and Rust contract bindings.

## Review

- `cargo clippy --workspace --all-targets --all-features -- -D warnings`
  and Swift strict-concurrency warnings are treated as errors.
- `swift format lint --strict` treats every formatter finding as an error.
  Apple CI applies it to added, copied, modified, and renamed Swift files. The
  repository predates this strict gate and still has full-tree format debt;
  `just swift-format-check` reports that backlog without weakening the gate on
  new changes. Run `just swift-format-check-changed <base>` to reproduce CI.
- `cargo audit` fails when the lockfile contains a known vulnerability; no advisory exceptions are configured.
- Contract CI rejects duplicate YAML keys and invalid OpenAPI 3.1 documents.
  It regenerates bindings into a temporary directory and fails on byte drift
  from the committed Swift, Rust, normalized JSON, manifest, and golden files.
