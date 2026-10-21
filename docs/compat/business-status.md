# Business command compatibility status

As of 2026-10-21, the native GitHub command layer has fixture-backed request
coverage for the core repository, status, issue, pull request, release, run,
search, workflow/actions, discussion, and ruleset families.  These commands
share `native/github_business.mbt`: parsing, repository resolution, raw REST
requests, response formatting, status handling, and trace operation names all
run through the same provider-neutral client used by `gh api`.

The [Mac repair record](../development/handoff-20261020-mac-repairs.md)
supersedes the earlier speculative pin/develop/revert routes and the old
`pr checks`/`pr status`/`issue status` behavior. The repair live matrix passed
28 cases with zero failures; the two deploy-key success cases that were pending
permission subsequently passed in the
[2026-10-21 continuation](../development/handoff-20261021-oauth.md), with cleanup.
The earlier matrix covers nonempty selected-field status JSON and pipe output,
legacy commit check states and exit codes, issue pin/unpin and linked branches,
rebase and revert state confirmation, deploy-key permission-denial output,
and cleanup. It does not establish every
flag, JSON field, TTY/watch behavior, or complete command parity.

## Implemented request boundaries

- `repo`: list, create, view, edit/rename, delete, fork and sync.  Clone is a
  local argv-only Git workflow; archive/unarchive, deploy-key, gitignore,
  license and repository-content requests are handled by the additional
  endpoint mappings in `native/github_business_extra.mbt`. Deploy-key add
  reads a file or stdin and defaults to read-only in
  `native/github_collaboration.mbt`.
- `status`: assignment/review GraphQL queries, mention notifications and
  received-event aggregation, including organization and exclusion filters.
  Exact upstream terminal presentation remains incomplete.
- `issue`: list, status, view, create, edit, close, reopen, delete, lock,
  unlock, transfer and comments.  Close/reopen supply the operation's
  `state` explicitly, lock carries the requested lock reason, and delete
  resolves the node id before sending GitHub's GraphQL `deleteIssue` mutation.
  Pin/unpin and linked branch creation use GraphQL mutations; status uses
  separate assigned/mentioned/authored collections. Issue lists exclude PR
  entries before counting the requested limit, including across pages.
- `pr`: list, view/edit/close/reopen, ready, merge, lock/unlock, create,
  checks, review, comments and diff.  `ready` sends `draft=false`; diff uses
  the GitHub diff media type; checkout is a separate argv-only Git workflow.
  Merge maps `--merge`/`--squash`/`--rebase` and `--match-head-commit` to
  their REST fields and rejects conflicting strategies before HTTP.
  Checks resolve the PR node and paginate its latest commit's contexts.
  Status aggregates current-branch/authored/review-requested PRs. Update-branch
  and revert use GraphQL with the expected head SHA for branch updates.
- `release`: list, view latest/tag, create, edit, delete and delete-asset.
  Download resolves release metadata, filters assets by a bounded glob,
  fetches binary asset bytes, and writes them to a validated directory.
  Delete-asset accepts `<tag> <asset-name>` and resolves an exact asset name to
  its numeric ID before deletion. Download follows at most five explicit
  redirects; GitHub.com's trusted release asset hosts receive no API
  credentials, and signed URL queries are excluded from traces.
  Upload resolves the release id and metadata `upload_url`, reads bounded local
  files, and sends each asset to the validated uploads origin as an
  octet-stream request with its `name` query parameter.
- `run`: list, view, cancel, rerun, rerun-failed, delete, logs and artifacts.
  `run watch` polls the run endpoint with configurable `--interval` and
  `--timeout`; terminal conclusions stop polling and `--exit-status` maps a
  non-success conclusion to exit code 1.
- `search`: issues/PRs, repositories, code and commits.  Search qualifiers
  are folded into GitHub's `q` expression, with sort/order/limit remaining
  ordinary query parameters.  `search prs` adds `is:pr`.
- `project`: Projects V2 owner resolution and basic create/list/view/edit/
  close/reopen/delete use GraphQL. Item and field management remain pending.
  `discussion`: read-only list/view requests use GraphQL and unwrap the
  `data` envelope before field projection. Historical REST `/projects` and
  `/discussions` paths are rejected instead of being sent to GitHub.
- `secret` and `variable`: repository, organization, and environment routes
  are mapped to their Actions endpoints. Secret writes fetch the published
  public key and use a libsodium-compatible sealed box. Variable set follows
  v2.102.0: POST the collection, then PATCH the named item only after HTTP 409.
  Values remain strings; other HTTP failures are returned without a fallback
  write. Organization variable visibility defaults to private, with explicit
  all/private supported; selected-repository access remains outside this slice.

REST collection commands with `--limit` above 100 follow the response `Link`
header, preserve the configured Enterprise API prefix, reject cross-origin
links, and fail on a repeated link.  Project and discussion GraphQL lists use
the selected connection's `pageInfo.endCursor`, reject a repeated cursor, and
keep the first response headers available to `--include`; merged output only
changes the collection array.

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

The 2026-10-18 write lifecycle against `ZSeanYves/gh_test` passed issue,
branch/PR, release create/edit/upload/delete-asset/delete, and secret
set/list/delete checks. Cleanup passed with no residual resources. The
earlier variable result was invalid evidence: the implementation used PUT,
which is not a variable create/update method. The
`X-Accepted-GitHub-Permissions` header states the endpoint's requirements,
not the credential's granted permissions, so it cannot establish that the
token is read-only. The corrected fixture records real write failures,
checks create/update values in memory, and tracks successful mutations for
cleanup independently of output assertions. The 2026-10-19 corrected live
run verified variable create/read/update/read/list/delete and secret
set/list/delete with the updated local credential. The final expanded run
also verified absence after deletion, PR comment/review/edit/close/reopen/merge,
merged target SHA and content, and release create/edit/upload/download with
byte equality/delete-asset by name/delete/tag deletion. Both PR branches were
marker-owned, and the default branch SHA was unchanged.

The sanitized report `/tmp/gh-live-write-20261019b.json` has 59 executed cases
passing, 10 explicitly skipped cases, zero failures, and successful cleanup
with no active residual resources. Merged PR history remains visible on
GitHub; no PR deletion is claimed. The retained
[sanitized summary](live-write-20261019.json) records the tested binary hash,
executed and skipped case names, and Native 203 / Wasm 68 / Wasm-GC 51 / JS 68
passing tests. Warning-denying checks, release build, both live-runner
self-tests, interface generation, and formatting checks also passed.

`write_operations_verified` is scoped to executed lifecycle cases. The 10
skips cover null-description repository edit, eight Actions run/workflow
operations, and cache creation; these remain unverified.
`core_parity_verified` remains false, and this run does not replace a full
oracle differential or the outstanding OAuth, keyring, and interaction gates.

## Boundaries

Release download/upload are intentionally byte-safe but remain a bounded
client implementation and do not implement every release asset archive or
checksum option.  Download supports a local directory, clobber policy and a
simple `*` glob; shell expansion is never used. Redirects remain disabled for
ordinary API calls. The explicit SDK asset download method accepts only the
release asset route, limits redirect hops to five, and supports same-origin
Enterprise redirects or GitHub.com's two allowlisted release CDN hosts.
Cross-origin Enterprise object stores and assets over the native 16 MiB
response limit remain outside this slice.

`run watch` uses a bounded polling loop and fixture-friendly integer timeout;
full terminal UI rendering, log streaming, and every interactive watch flag
remain outside this slice. Discussion mutations still require
their GraphQL mutation cases; complete release asset
archive extraction, PR checkout/review interaction, and special integrations
(`codespace`, `copilot`, `agent-task`, `attestation`, extension, skills,
telemetry, preview and accessibility) are tracked separately.

The 2026-10-19 account slice adds file-backed gist create/edit/add/remove/rename,
SSH authentication/signing key handling, GPG public-key input, Projects V2
owner resolution and basic create/list/view/edit/close/reopen/delete, and status
assignment/review/mention/activity aggregation. Controlled REST/GraphQL and
loopback tests cover request shapes, error paths and body-free traces.
No real account-level mutations have been accepted yet. Gist interactive editor,
clone/web, truncated raw retrieval and multi-page list limits remain incomplete;
Project item/field management and exact terminal formatting also remain outside
this slice. Status terminal layout, complete sorting/limits/cache and partial
authorization recovery still need parity work. See the
[auth/account acceptance guide](../development/auth-acceptance.md).
The [authentication/account validation record](auth-account-20261019.json)
records the new build and 259/259 whole-tree Native regression tests. It is
separate from the earlier repository live-write report and does not extend
that report's real-world evidence to the new binary.

The injected-transport fixtures establish core request and output behavior
without invoking upstream `gh` or contacting GitHub. The separately gated
live lifecycle contacts only the authorized disposable repository, receives
credentials through its environment, and persists sanitized result metadata.
