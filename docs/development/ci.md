# GitHub compatibility CI

The [workflow source](../../.github/workflows/ci.yml) validates the GitHub
mainline on pushes, pull requests, and manual dispatch. Native jobs execute on
Linux x64, macOS arm64, and Windows x64 with the pinned MoonBit toolchain/core
`0.10.14+7d59c7ec9`. Action revisions are pinned in the workflow.

## Required checks

The workflow checks formatting, regenerates public interfaces, and rejects
unexpected generated-interface changes. Native checks deny MoonBit warnings;
Native tests and the Native release build run on each platform. Portable
checks and tests cover Wasm, Wasm GC, and JavaScript separately. The live
GitHub runner executes only `--self-test` in ordinary CI.

Reproduce the principal checks from the repository root:

```text
moon check --target native --frozen --deny-warn
moon test --target native --frozen
moon check --target wasm --frozen --deny-warn
moon test --target wasm --frozen
moon check --target wasm-gc --frozen --deny-warn
moon test --target wasm-gc --frozen
moon check --target js --frozen --deny-warn
moon test --target js --frozen
moon build --target native --release --frozen --deny-warn cmd/main
moon check --target native --deny-warn scripts/live_github_fixture.mbtx
moon run --target native scripts/live_github_fixture.mbtx -- --self-test
moon info
moon fmt
```

Run Moon commands sequentially because they share a build lock. Review changes
to generated `.mbti` files after `moon info`; do not edit them manually. See
[release validation](release.md) for oracle capture and live acceptance.

Each Native job uploads its built executable as
`gh-<platform>-<commit>` for 14 days when available. An artifact may also be
uploaded after a failed job; artifact presence is not a passing validation
result or a signed release.

## Evidence boundaries

The native package tests exercise controlled transports, loopback HTTP, local
files, process arguments, and synthetic credentials. The runner self-test
checks the live harness without contacting a real account. Neither is a live
GitHub integration run, and ordinary CI must not receive real account tokens.
Portable tests cover portable packages only, not a Wasm or JavaScript CLI.

Successful local commands do not prove that the new workflow has passed on
every hosted runner. Review the actual workflow run and source revision before
claiming hosted coverage. Historical MoonHub hosted runs and candidate
manifests remain on `codex/moonhub-adapter`; they are not evidence for this
GitHub-only workflow or a newly built executable.

System HTTPS trust, invalid-certificate rejection, credential backend behavior,
PTY/editor/browser interaction, and release distribution need their own host
acceptance. The pinned async library may emit upstream C compiler diagnostics;
`--deny-warn` governs MoonBit diagnostics, not upstream C warnings.
