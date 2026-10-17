# GitHub CLI compatibility in MoonBit

[![Native CI](https://github.com/moonbit-community/gh/actions/workflows/ci.yml/badge.svg)](https://github.com/moonbit-community/gh/actions/workflows/ci.yml)

A GitHub-first MoonBit CLI and SDK targeting the pinned GitHub CLI
**v2.102.0** behavior for commands, authentication, raw REST/GraphQL requests,
output, and exit status.

The core command tier is implemented and validated against loopback fixtures and
the pinned oracle. This branch claims **v2.102.0 core parity** for the command
families listed in the [compatibility contract](docs/compat/gh-v2.102.0.md).
The separate [oracle evidence status](docs/compat/oracle-status.md) records the
captured upstream behavior, fixture evidence and limits. Full built-in command
parity remains deferred for release-specific integrations.

## Direction

- Provider-neutral raw HTTP transport with byte-preserving requests and responses.
- A GitHub facade, command layer, and Native composition independent of MoonHub.
- `gh api`, repository/status, issue/PR/discussion, release/Actions, search,
  organization/project and credential-management commands with typed operations,
  output filters and Native interaction seams.
- Explicit retries, redacted tracing, and reproducible fixture/oracle acceptance.
- MoonBit project sources and automation; upstream Native FFI and controlled
  system git, editor, browser, and credential adapters are allowed.

The existing `moonhub/` and `cli/` packages are frozen migration assets. Their
old `/api/v1` proposal is not the GitHub protocol. Future MoonHub adaptation
will use its real `/-/api/v1` service after GitHub core parity.

## Development

The Native executable and portable packages are validated separately. Portable
tests do not imply that Native network, files, or process behavior runs on
Wasm, Wasm GC, or JavaScript.

```text
moon check --target native --frozen
moon test --target native --frozen
moon run --target native cmd/main -- --help
```

Capture the pinned upstream oracle using a separately supplied v2.102.0 binary:

```text
moon run --target native scripts/gh_oracle.mbtx -- /absolute/path/to/gh-v2.102.0 OUTPUT_DIR [EXPECTED_BINARY_SHA256]
```

The runner uses isolated credentials and literal process arguments. Capturing
upstream help and local errors is reference collection, not proof that this
implementation matches. The [documentation index](docs/README.md) identifies
current GitHub work and the retained legacy MoonHub guides.
