# Documentation

This branch targets GitHub CLI v2.102.0 compatibility in MoonBit. The listed
core command tier has reached its parity milestone; release-specific
integrations remain deferred. The previous MoonHub provider remains frozen for
migration tests.

## GitHub compatibility

- [Architecture and provider boundaries](architecture.md)
- [Pinned command and behavior inventory](compat/gh-v2.102.0.md)
- [Oracle provenance, verified behavior, and acceptance gaps](compat/oracle-status.md)
- [Captured command and flag inventory](../testdata/gh-oracle/v2.102.0/inventory.md)
- [Oracle runner](../scripts/gh_oracle.mbtx)
- [Live GitHub account testing and replay boundaries](compat/live-github-fixture.md)

## Frozen MoonHub usage

These guides describe the legacy provider. They are not the GitHub CLI contract
or a claim that MoonHub's real `/-/api/v1` service accepts the old proposal.

- [CLI commands and configuration](guides/cli.md)
- [SDK and transport injection](guides/sdk.md)
- [Request tracing](guides/tracing.md)
- [Read retries](guides/retries.md)

## Frozen MoonHub API contracts

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
