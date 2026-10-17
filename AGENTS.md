# Project Agents.md Guide

This is a [MoonBit](https://docs.moonbitlang.com) project.

## Project-specific architecture

The `master` branch contains only the GitHub command-line client and SDK.
The compatibility oracle is pinned to GitHub CLI v2.102.0. Core command parity
is the first milestone; full built-in command compatibility requires the
separately tracked integrations to pass their own acceptance cases. Help
snapshots alone do not establish implementation compatibility.

- The root package owns provider-neutral request, response, error, and trace
  contracts.
- `github/` owns GitHub configuration, raw REST/GraphQL calls, and provider
  behavior; command-specific typed operations belong in `github/operations/`.
- `github_cli/` owns GitHub parsing, output, and exit-code policy.
- `codex/moonhub-adapter` preserves the pre-split MoonHub DTOs, configuration,
  commands, test assets, and historical documentation. These packages are not
  part of the `master` working tree or dependency graph.
- `cmd/main/` is the thin native executable entrypoint.
- `native/` composes upstream HTTP, authentication, process, and JSONL adapters.
  Its public API uses root or deliberately public provider-owned types.
- Future transport, auth, persistence, and redaction helpers belong in focused
  packages under `internal/`; public concrete types stay in the facade or a
  deliberately public package.
- Continue GitHub compatibility work on `master`. Future MoonHub work belongs
  on `codex/moonhub-adapter`, after GitHub core parity, and must follow the real
  `/-/api/v1` client protocol rather than the historical `/api/v1` proposal.
  MoonHub server database/Web packages remain outside client dependencies.
  Browser HTML, cookies, and CSRF forms are not a CLI transport.
- Prefer suitable community/upstream MoonBit packages before implementing a
  general capability. Keep project code focused on provider policy; record why
  an existing package is unsuitable before replacing it. Project sources and
  automation remain MoonBit (`.mbt`/`.mbtx`); upstream FFI is allowed.

The scope, dependency direction, trace policy, runtime targets, and current
architecture live in [`docs/architecture.md`](docs/architecture.md).
The pinned compatibility contract and evidence limits are in
[`docs/compat/gh-v2.102.0.md`](docs/compat/gh-v2.102.0.md) and
[`docs/compat/oracle-status.md`](docs/compat/oracle-status.md). Use the
[documentation index](docs/README.md) for current GitHub development. The old
`docs/guides/`, `docs/contracts/`, and `docs/report/` are preserved only on
`codex/moonhub-adapter`; they do not define the GitHub contract.

You can browse and install extra skills here:
<https://github.com/moonbitlang/skills>

## Project Structure

- MoonBit packages are organized per directory; each directory contains a
  `moon.pkg` file listing its dependencies. Each package has its files and
  blackbox test files (ending in `_test.mbt`) and whitebox test files (ending in
  `_wbtest.mbt`).

- In the toplevel directory, there is a `moon.mod` file listing module
  metadata.

## Coding convention

- MoonBit code is organized in block style, each block is separated by `///|`,
  the order of each block is irrelevant. In some refactorings, you can process
  block by block independently.

- Try to keep deprecated blocks in file called `deprecated.mbt` in each
  directory.

## Tooling

- `moon fmt` is used to format your code properly.

- `moon ide` provides project navigation helpers like `peek-def`, `outline`, and
  `find-references`. See $moonbit-agent-guide for details.

- `moon info` is used to update the generated interface of the package, each
  package has a generated interface file `.mbti`, it is a brief formal
  description of the package. If nothing in `.mbti` changes, this means your
  change does not bring the visible changes to the external package users, it is
  typically a safe refactoring.

- In the last step, run `moon info && moon fmt` to update the interface and
  format the code. Check the diffs of `.mbti` file to see if the changes are
  expected.

- Run `moon test` to check tests pass. MoonBit supports snapshot testing; when
  changes affect outputs, run `moon test --update` to refresh snapshots.

- Prefer `assert_eq` or `assert_true(pattern is Pattern(...))` for results that
  are stable or very unlikely to change. For snapshot tests that record
  structured debugging output, derive `Debug` and use `debug_inspect`, rather
  than deriving `Show` for debugging. For solid, well-defined results (e.g.
  scientific computations), prefer assertion tests. You can use
  `moon coverage analyze > uncovered.log` to see which parts of your code are
  not covered by tests.
