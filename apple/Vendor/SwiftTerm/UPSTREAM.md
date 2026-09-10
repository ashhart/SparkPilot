# SwiftTerm library distribution

Source: https://github.com/migueldeicaza/SwiftTerm
Release: 1.20.0
Revision: 5d14406844143538cd8f8851d2d8a67c1fe443e5
License: MIT, retained in LICENSE.

Sources/SwiftTerm includes SparkPilot terminal integration changes and
SwiftTermBuildInfo.swift, which records the fixed upstream release identity.
Buffer.dump() writes to the platform temporary directory instead of an upstream
developer’s home directory; UPSTREAM-SHA256.json retains the upstream baseline
for reviewing local changes, while `local_source_hashes` in
`docs/build/source-lock.json` pins each reviewed modified file.
The source checker rejects changes to either an upstream file or a local patch.
The local package includes the library and Metal resource only; upstream CLI,
fuzzer, documentation dependencies and Git build-information generator are not
part of the app. This avoids requiring executable package plugins or machine
Git metadata for reproducible app builds; Xcode plugin validation stays enabled.

To update, check out the exact upstream tag, review its changes and license,
replace Sources/SwiftTerm, retain the fixed build-info file with the new identity,
then regenerate UPSTREAM-SHA256.json from upstream files and run terminal and
Apple platform build tests. Verify each upstream file against that manifest.
