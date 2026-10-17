# Business command compatibility status

As of 2026-10-16, the native GitHub command layer has fixture-backed request
coverage for the core repository, status, issue, pull request, release, run,
search, workflow/actions, discussion, and ruleset families.  These commands
share `native/github_business.mbt`: parsing, repository resolution, raw REST
requests, response formatting, status handling, and trace operation names all
run through the same provider-neutral client used by `gh api`.

## Implemented request boundaries

- `repo`: list, create, view, edit/rename, delete, fork and sync.  Clone is a
  local argv-only Git workflow; archive/unarchive, deploy-key, gitignore,
  license and repository-content requests are handled by the additional
  endpoint mappings in `native/github_business_extra.mbt`.
- `status`: notification listing with `--all`, `--participating`, `--since`
  and `--before` query parameters.
- `issue`: list, status, view, create, edit, close, reopen, delete, lock,
  unlock, transfer and comments.  Close/reopen supply the operation's
  `state` explicitly, and lock carries the requested lock reason.
- `pr`: list, view/edit/close/reopen, ready, merge, lock/unlock, create,
  checks, review, comments and diff.  `ready` sends `draft=false`; diff uses
  the GitHub diff media type; checkout is a separate argv-only Git workflow.
- `release`: list, view latest/tag, create, edit, delete and delete-asset.
  Download resolves release metadata, filters assets by a bounded glob,
  fetches binary asset bytes, and writes them to a validated directory.
  Upload resolves the release id, reads bounded local files, and sends each
  asset as an octet-stream request with its `name` query parameter.
- `run`: list, view, cancel, rerun, rerun-failed, delete, logs and artifacts.
  `run watch` polls the run endpoint with configurable `--interval` and
  `--timeout`; terminal conclusions stop polling and `--exit-status` maps a
  non-success conclusion to exit code 1.
- `search`: issues/PRs, repositories, code and commits.  Search qualifiers
  are folded into GitHub's `q` expression, with sort/order/limit remaining
  ordinary query parameters.  `search prs` adds `is:pr`.

Business long flags are checked against the registered value/boolean option
set before any transport call.  Misspellings such as `--sttae` return an
`unknown flag` error instead of being silently ignored.  The parser still
leaves command-specific short aliases to their command implementation.

## Fixture evidence

The Native business suite uses an injected raw transport for exact method,
path, query, headers, body, binary response and output assertions.  It also
contains a loopback HTTP server that exercises repository, status and release
requests through the real Native HTTP adapter.  Release download/upload tests
use temporary files and binary bytes; the run-watch test returns an
`in_progress` response followed by a failed completed response and verifies
poll count and `--exit-status`.

The focused package gate currently passes:

```text
moon check --target native --frozen
moon test --target native --frozen -p ZSeanYves/gh/native
```

The recorded native package run for this implementation slice passed 77/77
tests. That historical count is not the GitHub-only branch's current total;
whole-tree validation after the split reports its own counts. Tests that
mutate process-wide browser or Git environment variables should be isolated
when diagnosing parallel-suite failures.

## Boundaries

Release download/upload are intentionally byte-safe but remain a bounded
client implementation: upload currently uses the configured REST origin for
the asset endpoint and does not implement every release asset archive or
checksum option.  Download supports a local directory, clobber policy and a
simple `*` glob; shell expansion is never used.

`run watch` uses a bounded polling loop and fixture-friendly integer timeout;
full terminal UI rendering, log streaming, and every interactive watch flag
remain outside this slice.  Projects v2, gist file mutation, complete release
asset archive extraction, PR checkout/review interaction, and special
integrations (`codespace`, `copilot`, `agent-task`, `attestation`, extension,
skills, telemetry, preview and accessibility) are tracked separately.

These fixtures establish core request and output behavior without invoking the
upstream `gh` binary, contacting GitHub, or storing real credentials.
