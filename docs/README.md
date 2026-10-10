# Documentation

MoonHub `gh` is a MoonBit CLI and SDK for MoonHub's proposed JSON API. Native
client behavior is tested with HTTP fixtures; real-server integration is pending.

## Usage

- [CLI commands and configuration](guides/cli.md)
- [SDK and transport injection](guides/sdk.md)
- [Request tracing](guides/tracing.md)
- [Read retries](guides/retries.md)

## API contracts

- [Read endpoints and DTOs](contracts/read-api.md)
- [Mutations, ETags and outcomes](contracts/mutation-api.md)
- [Pipelines](contracts/pipeline-api.md)
- [Generic JSON API command](contracts/api-command.md)

## Development and delivery

- [Architecture](architecture.md)
- [Cross-platform CI](development/ci.md)
- [Building, verifying and releasing](development/release.md)
- [Dependencies, attribution and TLS runtime](development/dependencies.md)

[Historical reports](report/README.md) retain implementation decisions, reviews
and execution evidence for their original revisions.
