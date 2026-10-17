# GitHub CLI compatibility in MoonBit

[![Native CI](https://github.com/moonbit-community/gh/actions/workflows/ci.yml/badge.svg)](https://github.com/moonbit-community/gh/actions/workflows/ci.yml)

A GitHub-first MoonBit CLI and SDK targeting the pinned GitHub CLI
**v2.102.0** behavior for commands, authentication, raw REST/GraphQL requests,
output, and exit status.

**v2.102.0 core parity is the current development target.** Implemented command
paths have loopback fixtures, selected oracle comparisons, and a recorded
20-probe live read-only run. These results do not establish complete core
parity. The [compatibility contract](docs/compat/gh-v2.102.0.md),
[oracle evidence status](docs/compat/oracle-status.md), and
[live fixture record](docs/compat/live-github-fixture.md) describe the verified
behavior and remaining limits. Full built-in command parity also requires the
separately tracked release-specific integrations.

## Direction

- Provider-neutral raw HTTP transport with byte-preserving requests and responses.
- A GitHub facade, command layer, and Native composition independent of MoonHub.
- `gh api`, repository/status, issue/PR/discussion, release/Actions, search,
  organization/project and credential-management commands with typed operations,
  output filters and Native interaction seams.
- Explicit retries, redacted tracing, and reproducible fixture/oracle acceptance.
- MoonBit project sources and automation; upstream Native FFI and controlled
  system git, editor, browser, and credential adapters are allowed.

## Branches

- `master`: the pure GitHub implementation and the active compatibility mainline.
- `codex/moonhub-adapter`: the complete pre-split snapshot, including the
  historical MoonHub implementation, fixtures, and delivery tooling.

The snapshot is commit `da3ef15`; removing those files from `master` does not
delete them from the preservation branch or Git history. Switch branches with
a clean working tree:

```text
git switch master
git switch codex/moonhub-adapter
```

Future MoonHub adaptation uses its real `/-/api/v1` service and follows GitHub
core parity. Its historical `/api/v1` proposal is preserved for reference only.

## Development

The Native executable and portable packages are validated separately. Portable
tests do not imply that Native network, files, or process behavior runs on
Wasm, Wasm GC, or JavaScript.

```text
moon check --target native --frozen --deny-warn
moon test --target native --frozen
moon run --target native scripts/live_github_fixture.mbtx -- --self-test
moon run --target native cmd/main -- --help
```

Capture the pinned upstream oracle using a separately supplied v2.102.0 binary:

```text
moon run --target native scripts/gh_oracle.mbtx -- /absolute/path/to/gh-v2.102.0 OUTPUT_DIR [EXPECTED_BINARY_SHA256]
```

The runner uses isolated credentials and literal process arguments. Capturing
upstream help and local errors is reference collection, not proof that this
implementation matches. The [documentation index](docs/README.md) identifies
current GitHub work and the separate MoonHub preservation branch. See
[development checks](docs/development/release.md) for portable targets and
release evidence requirements.
