# Proposed MoonHub v1 pipeline API

Status: **client proposal and compatibility fixtures for Increment 4**. The
separate MoonHub checkout at `672b8b5` contains the pipeline domain and browser
controls, but does not expose these `/api/v1` endpoints. Client fixtures do not
prove real server authorization, cancellation or execution. This contract reuses
the [read envelope and pagination](read-api-contract.md) and
[mutation outcomes and opaque preconditions](mutation-api-contract.md).

## Routes and wire data

All routes below are prefixed with `/api/v1/repos/{owner}/{repo}`. The run number
is repository-local, not a global database ID or a runner attempt ID.

| Method and suffix | Request | Success |
| --- | --- | --- |
| `GET /pipelines?page=1&per_page=30` | No body | 200 `Pipeline[]`, optional next Link |
| `GET /pipelines/{number}` | No body | 200 `Pipeline`, strong ETag |
| `POST /pipelines/{number}/cancel` | `{}`, exact strong If-Match | 202 `PipelineCancelReceipt` |
| `POST /pipelines/{number}/rerun` | `{}`, exact strong If-Match | 201 newly created `Pipeline`, strong ETag |

Each success body is `{"version":1,"data":T}`. A `Pipeline` contains:

```json
{
  "number": "42",
  "workflow_path": ".github/workflows/build.yml",
  "workflow_name": "Build",
  "source_branch": "main",
  "commit_sha": "0123456789abcdef0123456789abcdef01234567",
  "state": "running",
  "conclusion": null,
  "created_at": "2026-10-09 00:00:00"
}
```

`number` is a canonical decimal **string** in `1..9223372036854775807`. The
MoonHub domain uses `Int64`; using a string preserves values beyond the exact
JSON/JavaScript integer range and avoids introducing the earlier Issue/MR
client's Int32 bound. SDK arguments and CLI positionals use the same spelling:
no signs, whitespace, leading zeros, exponent, decimal point or separators.

`state` is exactly `queued`, `running`, or `completed`. Only `completed` has a
non-null `conclusion`, which is one of `success`, `failure`, `cancelled`,
`timed_out`, or `lost`. `skipped` applies to jobs, not run summaries: the shared
server conclusion enum includes it, but the run table excludes it.
Queued/running conclusions are null (an absent
optional conclusion is accepted as null). A completed run without a conclusion,
or a live run with a conclusion, is rejected. Lifecycle and conclusion are
separate fields, matching MoonHub's database invariant. `commit_sha` accepts
40 or 64 lowercase hexadecimal characters, matching `gitops.valid_commit_sha`.
The remaining fields are strings; timestamps are retained without timezone
reinterpretation. Unknown object fields are ignored for additive compatibility.

The summary intentionally omits workflow source, normalized workflow JSON,
hidden Git pin refs, internal database IDs, provider credentials, logs and
attempt credentials. Job/step detail, log streaming, workflow dispatch, provider
administration and push settings are outside this increment. `pipeline view`
returns a run summary rather than silently scraping the browser detail page.

Lists are newest first, scoped to readable repositories. They adopt the
existing explicit `page`/`per_page`, Link validation and bounded `--paginate`
policy. MoonHub's current `list_runs` instead has a fixed 50-row limit; server
work must add real paging rather than exposing that function as a complete list.
Like the other live collections, page-number navigation is not a snapshot:
concurrent inserts can shift later pages. No client deduplication is invented.

## Cancellation and snapshot reruns

Cancellation returns:

```json
{"version":1,"data":{"number":"42","kind":"cancel_requested"}}
```

202 and the SDK outcome `accepted` acknowledge a committed, durable cancellation
request. They do not assert that every runner has stopped, or that the eventual
run conclusion must be `cancelled`: lease loss can still produce `lost`.
Queued/waiting jobs can finish immediately; live attempts receive a stop request
and a bounded grace period. A caller observes the eventual outcome with
`pipeline view`. The API does not automatically poll.

A rerun requires a completed source run. It creates a **new run number** and
new Git pin from the original immutable commit and workflow snapshot; it must
not resolve the current branch or reparse its present workflow. The 201 body
describes the newly created `queued` run with null conclusion and a new ETag.
The SDK outcome `applied` confirms creation only, not execution or success.
The SDK rejects a receipt whose number equals the original number or whose
state is not queued. The server must serialize the committed creation snapshot
even if a runner claims work before the HTTP response is delivered.

The client sends no implicit preflight GET and therefore cannot independently
compare a rerun receipt's commit/workflow fields to the original run. Snapshot
fidelity is a server contract to verify with real server tests; the caller may
retain the inspected original and compare it with the returned new run.

Both writes require the caller's exact strong `If-Match`; there is no
automatic refresh, wildcard, weak tag or mutation retry. A pipeline's ETag must
cover the complete selected representation, including state/conclusion changes.
The server must compare it and apply cancellation/creation atomically within
its transaction/repository lock and recheck current permissions. Possession of
a valid tag never grants access. The read client tolerates a missing ETag for
compatibility, but conditional writes remain unavailable until the caller has
obtained one; the server contract requires it on individual reads.

Error status policy is 401 for authentication, 403 for insufficient permission,
404 for absent/inaccessible runs under the server's existence policy, 412 for a
stale tag, and 409 for state or current merge-check conflicts. In particular,
this **proposed machine API** rejects cancellation of an already completed run
with 409; the existing browser-backed cancellation function currently permits
that no-op. It maps rerunning an active run or an obsolete required check to
409 rather than copying browser form BadRequest handling. Malformed identifiers
are local errors and produce no HTTP attempt.

A cancellation accepted while a run is active can race with its final runner
report; preserve the existing domain's cancellation/completion ordering.
Repeated requests must not extend a cancellation deadline. Reruns are not
idempotent: another explicit rerun may create another snapshot. If a response
is lost, inspect run history before submitting anything again. Transport loss,
5xx, unexpected success status, invalid receipts and missing required ETags
produce `unknown`, and trace-sink failure does not replace the write outcome.

## Evidence and server review gate

Inspected local MoonHub source at `672b8b5`:

- `pipeline/store.mbt` defines separate run/job states and conclusions,
  repository-scoped run lookup, signed Int64 numbers and the current 50-row
  newest-first list. `db/migrations/007_pipelines.sql` enforces lifecycle and
  immutable snapshot constraints.
- `pipeline/runs.mbt:require_run_author` re-resolves the active identity,
  requires repository Write access and repository owner/admin or site-admin
  management privileges. `rerun_run` requires completion, uses the repository
  write lock, copies the original snapshot and obtains a new number/pin.
  Permissions are rechecked after asynchronous Git work and before publication.
- `pipeline/execution.mbt:Coordinator::cancel_run` uses an immediate transaction
  to set `cancel_requested`, complete queued/waiting jobs, set live attempts'
  first cancellation time, and finalize runs where possible. The runner lease
  logic preserves a fixed grace deadline, and expired stopping attempts can be
  marked lost.
- `pipeline/merge_checks.mbt:validate_merge_check_rerun` requires the latest
  check of an open, ready MR with the current revision/generation, unchanged
  source/target SHAs, an applicable required-check rule and no pending/running
  merge job. The public API must preserve those conditions under the lock.
- `pipeline/runs_wbtest.mbt` verifies immutable rerun snapshots after branch
  changes and distinct run numbers; `pipeline/execution_wbtest.mbt` covers
  queued cancellation, cancellation races and durable recovery.
- `web/views/pipelines/pipeline_pages.mbt` mounts browser routes with session
  identity and CSRF handling. `web/views/pipelines/runner_api.mbt` mounts the
  separate provider protocol. Neither is the public client transport.

Before production acceptance, the server owner must approve this DTO and status
mapping, implement public origin-bound Bearer authentication, paging, request-ID
echo and atomic ETags, then run the public HTTP contract against a real server.
Server tests must cover ordinary contributor denial, authorization revocation,
completed-run cancellation, stale preconditions, concurrent runner completion,
changed required-check context, immutable snapshot reruns and failed responses
after a committed snapshot. No server source is modified by this increment.

Compatibility bodies live in [`testdata/pipelines/`](../testdata/pipelines/):
`list.json`, `view.json`, `completed.json`, `cancel.json`, `rerun.json` and
`stale.json`. HTTP status and ETag are supplied by executable fixtures rather
than embedded in resource bodies. The SDK tests cover large numbers, malformed
lifecycle/conclusions, additive fields, two-page reads, exact If-Match, unknown
write outcomes, permission/conflict statuses and no retries of either write.
