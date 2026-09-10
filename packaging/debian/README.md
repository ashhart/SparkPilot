# Debian runtime packaging

`build.sh` cross-builds the complete Rust workspace in a pinned aarch64 Linux container and writes a reproducible Debian 2.0 package without requiring host `dpkg-deb`.

```sh
packaging/debian/build.sh
packaging/debian/build.sh --check-tree
packaging/debian/build.sh --binaries /path/to/aarch64-binaries --verify-reproducible
```

`SOURCE_DATE_EPOCH` controls archive timestamps; otherwise the last commit timestamp is used, with a fixed 2026-01-01 fallback outside Git.
`SPARK_BUILD_DIR`, `SPARK_OUTPUT_DIR` and `SPARK_DEBIAN_REVISION` allow isolated builds without overwriting existing artifacts.
The writer emits `debian-binary`, `control.tar.xz` and `data.tar.xz`; `inspect_deb.py --deb PACKAGE --expect-manifest --schema-version N` independently checks required files, modes, service arguments and forbidden credentials/state.
`mkdeb.py --help` lists the staging-directory, control-template, version, architecture and timestamp arguments.

## Upgrade invariants

Before unpacking, `preinst` confirms that service-account processes and the privileged helper are quiet, rejects redirected paths, probes schema compatibility with the outgoing binary, and takes a root-only SQLite `.backup` snapshot outside service-owned paths.
The service-uid scan includes arbitrary daemon children but excludes exited zombies; helper detection uses the systemd unit and exact kernel `/proc/<pid>/exe`, including its deleted-binary suffix.
The shared gate is injected into every maintainer script during packaging, with no force-kill policy.

`postinst` uses no-follow descriptor operations to seed directories, configuration and the signed bootstrap catalogue without replacing operator state.
Migration, service start and health verification form one rollback transaction.
On failure, data is restored and services stay stopped; the operator completes package rollback through dpkg because maintainer scripts do not replace package-owned binaries behind dpkg's back.
The root-only backup remains available after commit; only the in-flight marker is cleared.
Removal preserves identity and grants, while purge removes state and the service account only after quiescence, preventing reuse of a uid still held by a live process.

## Lifecycle QA

Mount this entire directory into a throwaway aarch64 Debian container and run `bash /tests/test_install.sh PACKAGE.deb [UPGRADE.deb]` as root inside that container.
The scenario runner sources `tests/install_support.sh` for assertions, identity/schema probes and process cleanup; its scenario ordering and checks remain in the runner.
The workflow in `.github/workflows/packaging.yml` installs the test dependencies and performs clean install, upgrade, symlink, live-process, zombie, WAL recovery, removal and purge checks.
Containers without systemd do not exercise unit activation, health gating or restart-on-failure; those remain separate systemd-host acceptance checks.
