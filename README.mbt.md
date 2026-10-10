# MoonHub `gh`

[![Native CI](https://github.com/moonbit-community/gh/actions/workflows/ci.yml/badge.svg)](https://github.com/moonbit-community/gh/actions/workflows/ci.yml)

A MoonBit port of `gh` adapted for MoonHub. It follows the command-oriented
shape of GitHub's `gh` so that humans and AI agents can use a
small, deterministic interface, while its protocol and domain model remain
owned by MoonHub.

The project is MoonHub-first. GitHub API compatibility is not a first-release
requirement. The implementation provides a provider-neutral request
and trace boundary, a MoonHub client, and commands for authentication,
repositories, issues, merge requests, pipelines, and a generic `api` escape
hatch.

The durable design is documented in [`docs/architecture.md`](docs/architecture.md).
Hosted Native checks and their acceptance boundary are documented in
[`docs/ci.md`](docs/ci.md).

## Current development

Increment 2 adds typed reads and a working native CLI: `meta`, `auth status`,
`repo list/view`, `issue list/view`, and `pr list/view`. It includes bounded
pagination, stable JSON output, tested exit codes and per-attempt redacted
traces. Argument parsing, JSON, HTTP/TLS, files and process exit use upstream
MoonBit libraries; there are no project FFI declarations or system HTTP tools.

Increment 3 adds Issue create/comment/close/reopen and MR create/comment/merge,
strong ETag preconditions, file/stdin body input and explicit write outcomes.
A merge response confirms queue acceptance; writes are never automatically
retried when the remote outcome is unknown.

Increment 4 adds `pipeline list/view/cancel/rerun`, offline `trace list/show`
with filters, bounded GET retries, request-ID correlation and compatibility
fixtures. Cancellation acknowledges a request; rerun creates a new run from
the original snapshot. `--max-attempts 1` disables read retries; writes remain
single-attempt. No new dependency or project FFI is introduced.

See [Increment 4 usage](docs/increment-4.md), the
[pipeline contract](docs/pipeline-api-contract.md), and
[release instructions and remaining gates](docs/release.md).

Increment 5 adds `api PATH` with explicit methods, bounded JSON file/stdin input,
validated custom headers and complete JSON responses. Generic requests always
send once, including GET, and expose the existing conservative write outcomes.
See [Increment 5 usage](docs/increment-5.md) and [API command contract](docs/api-command-contract.md).
Real MoonHub integration and platform/release acceptance remain open.

Increment 6 selects local Native delivery preparation. The candidate runner
builds a new directory, tests its staged executable, and records file hashes,
toolchain/platform coordinates and fresh smoke evidence in a completion
manifest. It does not publish a release or implement MoonHub's server API.
See [Increment 6 scope and evidence](docs/increment-6.md) and
[platform delivery instructions](docs/release.md).

See [Increment 3 usage and validation](docs/increment-3.md), the
[proposed mutation API contract](docs/mutation-api-contract.md),
[Increment 2 read commands](docs/increment-2.md), the
[proposed read API contract](docs/read-api-contract.md), and
[token configuration](docs/increment-1.md). Validation uses local HTTP contract
fixtures: the inspected MoonHub server still needs to implement `/api/v1`.

```sh
moon run cmd/main
moon run cmd/main -- issue list --host https://moonhub.example -R team/demo --json
moon run cmd/main -- api /meta --host https://moonhub.example --json
```

Use the repository's MoonBit checks before committing:

```sh
moon check --deny-warn
moon check --target all --deny-warn
moon test --target native --strip -j 1
moon build --target native --release --deny-warn
moon run --target native scripts/read_smoke.mbtx
moon run --target native scripts/mutation_smoke.mbtx
moon run --target native scripts/operations_smoke.mbtx
moon run --target native scripts/api_smoke.mbtx
moon info
moon fmt . scripts/read_smoke.mbtx scripts/mutation_smoke.mbtx scripts/operations_smoke.mbtx scripts/api_smoke.mbtx scripts/release_candidate.mbtx scripts/verify_candidate.mbtx scripts/release_smoke.mbtx
```

To create and verify a local delivery candidate from the repository root, run:

```sh
moon run --target native scripts/release_candidate.mbtx
```

The runner creates a new directory under `_build/releases`; pass an unused
output path after `--` to choose another location. Only a candidate containing
its completed `manifest.json` has passed the runner. Its `bin/moonhub-gh`
(`moonhub-gh.exe` on Windows) is the exact binary tested by the four suites.
Step logs and `runner-status.json` preserve diagnostics. Verify a candidate
without executing its binary using:

```sh
moon run --target native scripts/verify_candidate.mbtx -- _build/releases/local-candidate-1
```

Use the actual directory printed by the runner. A verifier copy is included in
the candidate and continues to work after the directory is moved. It validates
file inventory, hashes and recorded checks; it does not establish publisher
identity or replace a release signature. Candidate tooling regression is
available as `scripts/release_smoke.mbtx -- CANDIDATE` through `moon run`.
The manifest records `published: false` and `live_server_verified: false`.
[Hosted Native CI](docs/ci.md#execution-record) has passed on Linux x64, macOS
arm64 and Windows x64, with 134 tests, 66 CLI fixture scenarios and 16 release-tool
regressions per platform. These are fixture results; live MoonHub, TLS and
distribution acceptance remain separate gates in [release.md](docs/release.md).
