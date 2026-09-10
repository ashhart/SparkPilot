# Vendored CycloneDX schemas

Fetched once, committed, and never fetched again: the SBOM gate validates
offline and CI must not depend on a network round trip to a third party.

Both files are the unmodified originals from the CycloneDX specification
repository at the `1.5` tag.

| File | Source | SHA-256 |
|---|---|---|
| `bom-1.5.schema.json` | `https://raw.githubusercontent.com/CycloneDX/specification/1.5/schema/bom-1.5.schema.json` | `067f7824b08653839ea050ae9e09ca48375eadc2652b0e2a299476e7db90335b` |
| `spdx.schema.json` | `https://raw.githubusercontent.com/CycloneDX/specification/1.5/schema/spdx.schema.json` | `4f6e2b05c05d26a4f2dc5879fbc2fca94b0a28db46289d0c51345621b71cfbfc` |

`bom-1.5.schema.json` references `spdx.schema.json` relatively, which is why
both are here. `test_sbom_matrix.py` checks these hashes before validating, so
an edited schema fails rather than quietly weakening the gate.
