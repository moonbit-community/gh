# MoonHub CLI for MoonBit

[![Native CI](https://github.com/moonbit-community/gh/actions/workflows/ci.yml/badge.svg)](https://github.com/moonbit-community/gh/actions/workflows/ci.yml)

A MoonBit port of `gh` adapted for MoonHub, with a reusable SDK and predictable
commands for people and AI agents.

The client targets MoonHub's proposed versioned JSON API. Real MoonHub integration
is pending; GitHub API compatibility is outside the supported scope.

## Features

- Host and token configuration, API metadata, and authentication status.
- Repository listing and inspection.
- Issue listing, inspection, creation, comments, closing, and reopening.
- Merge request listing, inspection, creation, comments, and merge submission
  through `pr` commands.
- Pipeline listing, inspection, cancellation, and snapshot reruns.
- Generic JSON API requests with file or stdin input.
- Stable JSON output, documented exit codes, bounded pagination and read retries.
- Conditional writes using ETags and explicit mutation outcomes.
- Redacted request traces with offline search and request-ID correlation.
- An SDK with injectable transport, clock, and trace callbacks.

## Runtime support

- **Native:** the CLI, HTTP/TLS adapter, token-file configuration, and JSONL trace
  files. CI exercises Linux x64, macOS arm64, and Windows x64 with local HTTP
  fixtures; live-server and HTTPS deployment acceptance remain separate checks.
- **Wasm / Wasm GC / JavaScript:** portable request, SDK, parsing, and trace
  contracts are type-checked. Applications must supply their own host adapters;
  a runnable CLI and equivalent network/file support are not provided.

## Usage

From a source checkout, configure an existing token through `MOONHUB_TOKEN` or
`--config`, then run:

```sh
moon run cmd/main -- --help
moon run cmd/main -- repo list --host https://moonhub.example --json
moon run cmd/main -- issue list --host https://moonhub.example -R team/demo --json
```

See the [CLI guide](docs/guides/cli.md), [SDK guide](docs/guides/sdk.md), and
[documentation index](docs/README.md) for configuration, API contracts, and builds.
