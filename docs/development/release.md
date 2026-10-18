# Build and release validation

The module version is `0.1.0`; the compatibility oracle is GitHub CLI
`v2.102.0`. The `master` branch contains the GitHub implementation. Core parity
is still the acceptance target, with verified behavior and limits recorded in
the [oracle status](../compat/oracle-status.md) and
[live fixture guide](../compat/live-github-fixture.md). A successful build does
not publish a package or prove every upstream command is compatible.

The old MoonHub candidate builder, verifier, smoke runners, and historical
delivery reports are preserved on `codex/moonhub-adapter` at the pre-split
snapshot `da3ef15`. They are not part of the current GitHub release process.

## Development gates

Use the [CI-pinned toolchain](ci.md) and exact dependencies in `moon.mod`.
Fetch dependencies with `moon update` when preparing an environment, then
keep validation reproducible with `--frozen`. From the repository root:

```text
moon check --target native --frozen --deny-warn
moon test --target native --frozen
moon check --target wasm --frozen --deny-warn
moon test --target wasm --frozen
moon check --target wasm-gc --frozen --deny-warn
moon test --target wasm-gc --frozen
moon check --target js --frozen --deny-warn
moon test --target js --frozen
moon run --target native scripts/live_github_fixture.mbtx -- --self-test
moon check --target native --deny-warn scripts/live_github_write_fixture.mbtx
moon run --target native scripts/live_github_write_fixture.mbtx -- --self-test
moon build --target native --release --frozen --deny-warn cmd/main
moon info
moon fmt --check . scripts/gh_oracle.mbtx scripts/live_github_fixture.mbtx scripts/live_github_write_fixture.mbtx
```

Run these sequentially. Inspect generated public-interface and formatting
changes before committing. Native package tests use controlled HTTP/process
fixtures; the live runner's self-test uses no real token or account. Portable
test success establishes portable package behavior, not executable I/O on
those backends.

The Native release executable is
`_build/native/release/build/cmd/main/main.exe`. On a POSIX development host:

```text
./_build/native/release/build/cmd/main/main.exe --version
./_build/native/release/build/cmd/main/main.exe --help
```

Keep it under a distinct local name while comparing it with an installed
upstream `gh`; the fixed oracle must remain independently identifiable.
Native binaries must be built and tested for their actual OS/architecture.

## Oracle and live acceptance

Capture the pinned upstream reference with an independently supplied, verified
v2.102.0 executable and a fresh output directory:

```text
moon run --target native scripts/gh_oracle.mbtx -- /absolute/path/to/gh-v2.102.0 OUTPUT_DIR EXPECTED_BINARY_SHA256
```

The runner records exact help/error streams and provenance. It does not
automatically compare every implemented command or establish complete core
parity. Follow the [compatibility contract](../compat/gh-v2.102.0.md) for
parser, request, output, error, trace, and interactive acceptance.

Real GitHub tests are separate, explicit integration runs described in the
[live fixture guide](../compat/live-github-fixture.md). They require the
dedicated repository, a limited token supplied only through environment, and
the pinned oracle binary/hash when differential execution is requested. Record
the tested project binary hash, source revision, probe outcomes, and remaining
limits. Never commit credentials or raw private API output.

The recorded 2026-10-17 live run passed 20 read-only probes before the branch
split. It does not establish live acceptance for a later binary or prove
write lifecycles, OAuth/keyring/multiple-account behavior, all pagination, or
interactive output. Those scenarios require their own controlled resources,
cleanup, and oracle evidence.

## Distribution requirements

Before publishing a binary or claiming platform support, require passing CI
for that revision and host-specific checks for HTTPS trust, invalid-certificate
rejection, permissions/ACLs, cancellation, and process/credential adapters.
Packaging, signing, publication, and updates are not automated by the removed
MoonHub tools. A release needs its own reviewed process and must include:

- Project LICENSE and the complete required upstream attribution from the
  resolved dependency/toolchain sources; see [dependencies](dependencies.md).
- Source revision, toolchain and dependency versions, platform/architecture,
  binary hashes, and validation evidence tied to that exact binary.
- An explicit compatibility statement limited to completed acceptance cases.

File hashes show consistency, not publisher identity. Full built-in command
parity also requires the deferred integrations in the compatibility inventory.
