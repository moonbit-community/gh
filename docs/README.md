# Documentation

`master` is the pure GitHub CLI and SDK mainline. GitHub CLI v2.102.0 core
parity remains the implementation and acceptance target; selected fixtures and
the recorded live read-only matrix do not establish complete command parity.

## GitHub compatibility

- [Architecture and package boundaries](architecture.md)
- [Pinned command and behavior inventory](compat/gh-v2.102.0.md)
- [Oracle provenance, verified behavior, and acceptance gaps](compat/oracle-status.md)
- [Captured command and flag inventory](../testdata/gh-oracle/v2.102.0/inventory.md)
- [Oracle runner](../scripts/gh_oracle.mbtx)
- [Live GitHub account testing and replay boundaries](compat/live-github-fixture.md)
- [Business command fixture coverage](compat/business-status.md)
- [Authentication and local command boundaries](compat/credentials-status.md)
- [Repository context](compat/repository-status.md)
- [Raw transport](compat/transport-status.md)
- [SDK integration](compat/sdk-status.md)

## Development and delivery

- [Cross-platform CI](development/ci.md)
- [Building, validating, and release requirements](development/release.md)
- [Dependencies, attribution, and TLS runtime](development/dependencies.md)

## MoonHub preservation branch

`codex/moonhub-adapter` preserves the complete pre-split snapshot at `da3ef15`,
including `moonhub/`, the old `cli/`, provider-specific native adapters,
fixtures, smoke/candidate tooling, and `docs/guides`, `docs/contracts`, and
`docs/report`. Those directories are absent from the GitHub mainline. Their
historical `/api/v1` contracts do not describe the real `/-/api/v1` service.

Use `git switch master` for ongoing GitHub work and
`git switch codex/moonhub-adapter` to inspect or resume the preserved provider
with a clean working tree. Future shared fixes should be reviewed and applied
selectively; restoring the old provider tree is not part of GitHub development.
