# Tooling invariants

## Coverage matrices

The checked-in `coverage.json` registers define the acceptance cases checked by the matrix suites. The matrix suites always validate these registers in a self-contained checkout, without depending on the retired external PLAN.md.
A map entry must identify an existing test symbol or an explicit blocker with both its reason and the command needed to collect evidence.
An empty register, a case without evidence or a declared blocker, and missing test symbols fail the gate; file moves preserve a test's identity, and uncommitted test sources count as evidence. Add or retire acceptance cases explicitly in the register when scope changes.
Blockers and partial coverage remain visible in each run's output.
Accessibility also checks source wiring so an unused helper cannot satisfy a view requirement.
Hardware, layout, real-engine, gated-download and timed-idle requirements remain separate from in-process test coverage.

## Build and dependency checks

`tools/build-apple.sh` uses the reviewed resolved dependency graph without automatically resolving a replacement.
`tools/check-swift-dependencies.sh` compares exact package pins, resolved revisions and `docs/build/source-lock.json`; its `--update` mode updates that lock deliberately.
`tools/test-swift-dependencies.sh` changes each checked field in a scratch copy and verifies that the gate refuses it.
`tools/check-swift-api-surface.sh` compiles negative transport-access probes and positive supported-call probes, so removing all access cannot accidentally satisfy the security check.

## Release signing

`tools/release/spark_release.py` has separate `keygen`, `manifest`, `sign` and `verify` commands, with argparse help listing their options.
`keygen` creates an Ed25519 release key and trust entry, `manifest` assembles the unsigned artifact declaration, `sign` signs the manifest and every listed artifact, and `verify` requires no private key.
Key files are written outside the working tree, defaulting to `~/.spark-fabric/keys/`, with mode 0600; policy checks precede key creation and exclusive creation prevents replacement unless `--force` permits it.
Catalogue, package and manifest purposes remain separate, and schema-1 direct online-key trust supports only development and lab channels because it has no offline delegation root.

The canonical manifest-signing algorithm must match Rust and Swift:

1. Remove the `signature` member.
2. Recursively omit null object members, matching absent optional values in the other implementations.
3. Sort every object's keys; the contract's keys are ASCII.
4. Serialize compact JSON without whitespace.
5. Escape quotes, backslashes and controls below U+0020, retaining literal solidus and non-ASCII characters.

`contracts/fixtures/release-manifest-canonicalization.json` pins the same bytes in all three languages.
Artifact references remain plain filenames within the artifact directory even when their containing manifest has a valid signature.
Verification follows the installer's trust-key checks and ordering.
`tools/release/test_spark_release.sh` invokes every command as a process and checks refusal messages as well as exit status; the same-size tamper case isolates digest checking from length checking.

## Catalogue tooling

`tools/catalogue/spark_catalogue.py` signs, assembles, verifies and scaffolds model recipes:

```sh
spark_catalogue.py keygen --key-id catalogue-2026-b --key-dir DIR --root-out packaging/trust/catalogue-root.pub
spark_catalogue.py sign --key DIR/catalogue-2026-b.ed25519 --key-id catalogue-2026-b recipes/x.json
spark_catalogue.py assemble --key KEY --key-id KEY_ID --output packaging/catalogue/bootstrap.lab.json recipes/a.json recipes/b.json
spark_catalogue.py verify --root packaging/trust/catalogue-root.pub --key-id catalogue-2026-b packaging/catalogue/bootstrap.lab.json
spark_catalogue.py scaffold --github https://github.com/OWNER/REPO --output recipes/draft.json
```

Recipe and catalogue bytes follow the Rust declaration order, rather than the sorted-object algorithm used for release manifests.
Known fields follow `ModelRecipe::canonical_without_signature` and `SignedCatalogue::canonical_entries`; remaining fields retain input order and modeled absent optionals are omitted.
Runtime tests verify the assembled snapshot against the trust root.
A scaffold contains provenance for owner review and remains untrusted until signed.
Schema validation follows signing because the schema requires the signature value.

`publish.sh` checks every selected recipe against `packaging/catalogue/release-approvals.json` before signing or replacing any catalogue; approval pins the unsigned canonical recipe bytes, so changing an image, revision or profile requires review again.
With no arguments it considers every model recipe and refuses the entire operation if one is unapproved; pass explicit recipe paths to publish approved models while a candidate remains under review.
The TestFlight archive script applies the same check before building; standalone `sign` and `assemble` remain available for local qualification and do not establish release approval.
Carry forward an existing release only when its exact recipe is unchanged, and add new approval hashes only after completing `recipes/README.md` with evidence in the current release record.

## SBOM and appendix materialization

`tools/generate_sbom.py` reads the committed Cargo and Swift lockfiles without network resolution.
Output is sorted and excludes timestamps, hostnames and absolute paths so byte comparison detects drift.
Cargo components are keyed by name and version; Swift `bom-ref` values retain revisions even when packages share the same version, and Swift purls include their source host and owner.
The offline SBOM test uses provenance-checked CycloneDX and SPDX schema copies, including both SPDX reference spellings, with unknown references rejected rather than retrieved.
The pinned contract environment supplies validation dependencies; missing dependencies fail the gate.

The initial Appendix B materializer was retired once the committed contracts became authoritative.
Update the reviewed OpenAPI and schema files, then run `tools/generate-clients.sh`; replaying the original plan would restore obsolete API shapes and removed remote-access components.

## Runtime schema composition

`database/runtime-schema.sql` is a SQLite shell entry containing ordered `.read` directives for complete domain fragments in `database/schema/`.
Run it from the repository root; `tools/runtime_schema.py` expands the same entry for Python's `executescript` and refuses duplicate fragments, path escapes and unsupported directives.
`contracts/fixtures/runtime-schema-statements.json` records all 63 original statements in order, including pragmas, indexes and owner-protection triggers.
The regression test compares the expanded statements to that fixture and executes the result with foreign keys enabled.
Raw telemetry samples every 10 seconds compact into one-minute aggregates; larger windows merge numeric sum/count pairs associatively.
Schema comments retain the non-null usage key, directed-link peer identity, last-owner protection, closed telemetry vocabulary and associative sum/count merge rules.

## Offline release delegation

`tools/release/spark_release.py keygen --delegation-only` emits an online/offline key request; its schema-1 wrapper still cannot authorize production manifests.
An offline operator uses `delegate --root-record ROOT.json --root-key ROOT.ed25519 --online-keys REQUEST.json --version N --minimum-version N --not-before START --not-after END` to produce the schema-2 document defined by ADR-038.
The root record contains exactly one `release-delegation` public key, independently pinned by the operator; the command refuses a mismatched private key or wider online authority.
No real offline root is generated or stored by repository tooling or CI.
`just test-release` executes the CLI round trip and the shared adversarial corpus, and is part of `just ci`.
