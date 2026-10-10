# Native CI

[The workflow](https://github.com/moonbit-community/gh/actions/workflows/ci.yml)
runs on pushes, pull requests and manual dispatch. Each matrix job builds and
executes on its own host:

| Runner | Native target |
| --- | --- |
| `ubuntu-24.04` | Linux x64 |
| `macos-15` | macOS arm64 |
| `windows-2025` | Windows x64 |

The [workflow source](../../.github/workflows/ci.yml) pins MoonBit and core to
`0.10.14+7d59c7ec9` and pins actions to commits. Candidate manifests capture the
actual tool versions, dependencies, source identity and host details. Matrix
failures do not cancel other platforms, and no entry uses `continue-on-error`.

## Required checks

1. Verify source and `.mbtx` formatting, regenerate public interfaces and reject
   uncommitted generated-interface differences.
2. Run Native and all-target checks with `--deny-warn`, Native tests and a release
   build through the candidate runner.
3. Exercise version/help and read, mutation, operations and generic API fixtures
   against the staged executable.
4. Verify the candidate inventory and evidence, then run release-tool regressions,
   including the bundled verifier after moving a candidate copy.

The workflow reuses the repository's `.mbtx` runners. To reproduce its main
candidate checks from a source checkout, choose an output path that does not
already exist:

```sh
moon update
moon run --target native scripts/release_candidate.mbtx -- _build/ci-candidate
moon run --target native scripts/release_smoke.mbtx -- _build/ci-candidate
```

Run Moon commands sequentially because they share a build lock. See
[release tooling](release.md) for formatting, interface and individual smoke
commands, output paths, verification and failed-run handling.

## Inspect a run

Each job uploads `native-<platform>-<commit>` for 14 days. It contains the
candidate directory and `_build/release-smoke.json` when generated. Upload is
attempted after failures to preserve logs; a directory or uploaded artifact
alone does not establish success.

Require a successful job, `ci-candidate/manifest.json`, successful recorded
checks, complete file inventory, matching smoke binary identities and a release
regression report tied to that same manifest and binary. Missing output is an
incomplete or failed run. Use the bundled verifier to check downloaded files.

Artifacts are unsigned CI evidence. GitHub artifact ZIPs do not preserve POSIX
execute permissions; restore the executable bit before directly running a
downloaded Linux/macOS binary. Its bytes must still match the manifest. Keep
the verifier's build cache outside the candidate, as described in [release.md](release.md).

## Acceptance boundaries

Hosted Native fixture verification has passed on all three listed platforms.
The [archived execution report](../report/native-ci-2026-10-10.md) preserves the
source revisions, counts and hashes for those runs; each new run has its own
evidence.

The matrix exercises actual Native processes, loopback HTTP and temporary files.
All-target checking validates portable types; it does not execute a Wasm or
JavaScript CLI. Neither kind of check proves live MoonHub authorization or the
remote outcome of an interrupted write.

System HTTPS trust and invalid-certificate rejection, a full deployment
permission/Windows ACL review, signing and publication require separate
acceptance. See [release requirements](release.md#release-acceptance-requirements)
and [TLS runtime dependencies](dependencies.md#https-runtime-dependency).

The pinned async library can emit an upstream MSVC C4005 diagnostic for `EINVAL`.
`--deny-warn` applies to MoonBit diagnostics; upstream C diagnostics remain in
the captured build logs and should not be described as warning-free.
