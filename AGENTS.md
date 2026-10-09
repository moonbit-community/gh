# Project Agents.md Guide

This is a [MoonBit](https://docs.moonbitlang.com) project.

## Project-specific architecture

This repository is a MoonHub-first command-line client. It copies the
command-oriented shape of `gh` for predictable human and AI use; it does not
make GitHub API compatibility a first-release requirement.

- The root package owns provider-neutral request, response, error, and trace
  contracts.
- `moonhub/` owns MoonHub DTOs and client configuration. It must not import
  MoonHub's server database or Web packages.
- `cli/` owns command parsing, deterministic output, and exit-code policy. It
  depends on client contracts rather than on MoonHub storage.
- `cmd/main/` is the thin native executable entrypoint.
- `native/` composes the upstream HTTP, token-file, and JSONL adapters for SDK
  consumers. It returns public types owned by the root and `moonhub/` packages.
- Future transport, auth, persistence, and redaction helpers belong in focused
  packages under `internal/`; public concrete types stay in the facade or a
  deliberately public package.
- The MoonHub server API is a separate contract at `/api/v1`; browser HTML,
  cookies, and CSRF forms are not a CLI transport.
- Prefer suitable community/upstream MoonBit packages before implementing a
  general capability. Keep project code focused on MoonHub policy; record why
  an existing package is unsuitable before replacing it. Project sources and
  automation remain MoonBit (`.mbt`/`.mbtx`); upstream FFI is allowed.

The full scope, contracts, dependency direction, trace policy, runtime targets,
and implementation milestones live in [`docs/architecture.md`](docs/architecture.md).
The working SDK path and current runtime limits are in
[`docs/increment-1.md`](docs/increment-1.md).

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
