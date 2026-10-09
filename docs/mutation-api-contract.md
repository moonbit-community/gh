# Proposed MoonHub v1 mutation API

Status: **client proposal and contract fixtures for Increment 3**. The inspected
MoonHub server still lacks the public `/api/v1` API. These tests validate the
client, not server compatibility, authorization enforcement or actual merges.
The [read contract](read-api-contract.md) supplies the existing resource schemas,
versioned envelopes and origin-bound Bearer authentication.

## Routes and results

Every route below is prefixed with `/api/v1/repos/{owner}/{repo}`. Request bodies
are JSON objects. Every successful response is `{"version":1,"data":T}` with
the exact status listed. Browser form routes, cookies, CSRF fields and the
internal runner protocol are not used.

| Method and suffix | Request | Required If-Match | Success |
| --- | --- | --- | --- |
| `POST /issues` | `{title,description}` | No | 201 `Issue`, strong ETag |
| `POST /issues/{number}/comments` | `{body}` | No | 201 `CommentReceipt` |
| `POST /issues/{number}/close` | `{}` | Yes | 200 `Issue`, strong ETag |
| `POST /issues/{number}/reopen` | `{}` | Yes | 200 `Issue`, strong ETag |
| `POST /merge-requests` | `{title,description,source,target,draft}` | No | 201 `MergeRequest`, strong ETag |
| `POST /merge-requests/{number}/comments` | `{body}` | Yes | 201 `CommentReceipt` |
| `POST /merge-requests/{number}/merge` | `{}` | Yes | 202 `MergeReceipt` |

`CommentReceipt` has `number: Int` (the positive parent issue/MR number) and
`kind: "commented"`. It acknowledges an appended activity, without inventing
a separately addressable comment object or identifier. `MergeReceipt` has
`number: Int`, `version: DecimalString` and `job_status: "pending" | "running"`.
Versions follow the read contract's canonical decimal-string rules. Unknown
object fields are ignored. Optional ETags on receipt responses are validated
when present. Receipt bodies do not claim that a merge completed.

`MergeRequest` gains optional `job_status`, accepting `pending`, `running`,
`succeeded`, `failed`, or null/absent. `pr view --json` exposes this alongside
`status` and `merged_sha`, so callers can inspect the worker's later outcome.
The client does not automatically poll or retry the job. Raw server `job_error`
text is excluded from the public DTO and diagnostics.

The request title is trimmed before validation and serialization, and must
contain 1–200 MoonBit `String.length()` units (UTF-16 code units); descriptions
have a 20,000-unit limit. Comments must contain non-whitespace
text and have a 20,000-unit limit. Source and target identify branches in the
same repository; the server owns Git branch existence, comparison and merge
policy. No squash/rebase strategy, automatic branch deletion, review approval,
assignee selection, linked-issue editing or cross-repository MR is introduced.
Descriptions and comment bodies are serialized without trimming. The SDK rejects
identical source/target branches, blank branch text, controls and names over 1,024
`String.length()` units; full Git ref validation remains a server responsibility.

Fixtures in [`testdata/mutations/`](../testdata/mutations/) illustrate bodies.
ETags and HTTP statuses remain response metadata supplied by contract tests.

## Preconditions and ETags

`EntityTag` is an opaque, strong, quoted HTTP entity tag, at most 256 ASCII
characters including quotes. The client rejects weak tags, wildcard conditions,
lists, controls, unquoted values and duplicate ETag fields. It never constructs
a tag from `version` or `edit_version`. Read results now expose an optional
validated `etag`; the read CLI JSON envelope includes `etag`, with `null` when
absent. Callers obtain an ETag from a resource read, inspect that resource, then
explicitly pass that exact tag to a conditional mutation.

Mutation methods send one request. They do not secretly fetch a fresh ETag,
retry after a stale tag, bypass a precondition or replace the caller's decision
with the latest state. A stale tag returns 412. State or merge-policy conflicts
return 409. Server authorization is checked independently of tag possession.

The CLI requires explicit `--if-match` for conditional mutations. `--body` and
`--body-file PATH` are alternative body sources; `--body-file -` reads stdin.
The native input adapter limits input to 80,000 bytes and 30 seconds, decodes
UTF-8, then the SDK applies the 20,000 `String.length()` content limit. These
bounds prevent an unbounded file or pipe from delaying a command indefinitely.

The server must implement a **strong validator for the complete selected
representation**, not merely format `edit_version` as a string. Issue comments
change `updated_at` without incrementing `edit_version`; MR `status`, merge-job
state and `merged_sha` may change without either public version changing.
A representation digest or equivalent composite must account for every field
that can change its bytes. Compare the current tag and apply the mutation
atomically within the server's transaction/repository-lock boundary. A header
comparison before acquiring that boundary is insufficient.

For MR operations, `version` represents the source/target revision comparison;
`edit_version` represents editable metadata and state. Refresh the comparison
under the repository lock before issuing its current validator or accepting a
merge against it. A tag cannot replace permission, draft/state, approval or
required-check validation. The merge worker must retain its existing revision,
source/target SHA, permission, check and Git compare-and-swap safeguards.

Issue comments append activity independently of `edit_version`, so this
contract does not require If-Match for them. MR comments are attached to the
current comparison version, matching the existing domain rule, and require
If-Match. Neither kind of comment is idempotent.

## Mutation outcomes and failure handling

The SDK returns `MutationResult[T]` containing `value`, `trace_failed`, optional
`etag`, and a separate `outcome`. This tells automation whether a failure may
have followed an already applied write.

| Outcome | Meaning |
| --- | --- |
| `not_sent` | Local validation failed; no HTTP attempt was made. |
| `rejected` | An explicit HTTP 4xx response rejected the operation. |
| `applied` | The expected synchronous success response and resource/receipt were validated. |
| `accepted` | A valid 202 merge receipt confirms queue acceptance, not completion. |
| `unknown` | The request was attempted, but its remote write outcome cannot be established. |

Transport loss, HTTP 5xx or redirects, an unexpected success status, a malformed
success envelope/resource/receipt, or a missing required/invalid ETag all yield
`unknown`. Even a decoding failure after 201 may follow a committed write.
The caller must inspect the resource/server history before deciding whether
another write is appropriate. No mutation is automatically retried, including
create, comment, conflict, server failure or trace-sink failure. Idempotency keys
and automatic retry are not part of this increment.

401 and 403 preserve authentication/permission failures; 409 and 412 preserve
conflict classification. Error messages remain sanitized: request bodies,
titles/descriptions, branch text, tokens and arbitrary server prose are never
copied into failure diagnostics or trace records. One trace record describes
each actual HTTP attempt; later schema failure does not rewrite its HTTP
status. `trace_failed` is independent: a sink failure cannot turn `applied` or
`accepted` into a transport error or trigger another request.

## Existing MoonHub domain evidence and server work

The inspected source is the separate local MoonHub checkout. These paths
describe its current domain behavior; they are not imported by this client.

- `collaboration/issues.mbt:create_issue` validates content and requires
  repository Write access. `mutate_issue` allows contributor comments; other
  changes additionally require the author or a team administrator. Its status
  writes compare `edit_version` in the SQL update and increment it.
- `collaboration/merge_requests.mbt:create_merge_request` compares branches,
  rejects duplicate open requests for a source/target pair and prepares checks.
  `submit_merge_review` allows contributor comments only for the current
  comparison version. The prohibition on self-review applies to approval/review,
  not an author's plain comment.
- `collaboration/merge_requests.mbt:enqueue_merge` requires owner/admin access,
  validates the current version and blockers, then creates a `pending` job.
  `collaboration/merge_worker.mbt:execute_merge` performs the actual merge later
  and rechecks permissions, revision SHAs, approvals/checks and Git CAS.
- `collaboration/merge_checks.mbt:merge_checks_blocker` checks required workflows
  against the current comparison version and check generation.
- `web/app.mbt` mounts `/-/runner-api/v1`; browser mutation handlers in
  `web/views/issues/issue_routes.mbt` and
  `web/views/merge_requests/merge_routes.mbt` currently use protected forms.

The server owner must approve and implement machine routes, token permissions,
JSON envelopes, receipts, strong ETags and atomic If-Match behavior. Existing
domain `BadRequest(message)` cases must become stable status/code categories;
clients must not classify English error strings. API authorization tests and an
end-to-end run against that implementation remain separate acceptance work.
