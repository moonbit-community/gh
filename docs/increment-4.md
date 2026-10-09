# Increment 4: pipelines and operational tooling

This increment implements the client and local contract fixtures for the four
architecture deliverables. The public MoonHub server API is still proposed;
passing these fixtures does not establish live server integration or completion
of every first-release requirement. See the [release checklist](release.md) for
the remaining generic `api` command and server acceptance work.
The generic command was subsequently implemented in [Increment 5](increment-5.md);
this document retains the Increment 4 acceptance snapshot.

## Pipeline operations

```sh
moon run cmd/main -- pipeline list --host https://moonhub.example -R team/demo --json
moon run cmd/main -- pipeline view 42 --host https://moonhub.example -R team/demo --json
moon run cmd/main -- pipeline cancel 42 --if-match '"tag-from-view"' --host https://moonhub.example -R team/demo --json
moon run cmd/main -- pipeline rerun 41 --if-match '"tag-from-view"' --host https://moonhub.example -R team/demo --json
```

The [pipeline API contract](pipeline-api-contract.md) is grounded in MoonHub
`672b8b5`. It distinguishes `state` (`queued`, `running`, `completed`) from a
completed run's conclusion. Run numbers are repository-local decimal strings
within positive signed Int64, preserving exact values in JSON and AI tools.

Both control operations require an exact strong ETag from a preceding view.
Cancel returns 202 / `outcome: accepted`: the request is durable but runners
may still be stopping. Rerun returns 201 / `outcome: applied`: a new queued run
was created from the original commit/workflow snapshot. Neither response means
execution succeeded. List uses the same bounded pagination as issue/MR lists.
Logs, job detail, workflow dispatch and runner administration are outside this
increment.

## Read retries and correlation

All typed SDK GETs now use a configurable `ReadRetryPolicy`. The CLI defaults to
three attempts per page; `--max-attempts 1` disables retries and values up to 5
are accepted. The default backoff is 100 then 200 ms. Only transport failures
and HTTP 429/502/503/504 are retryable. A numeric `Retry-After` is a minimum wait;
invalid, repeated, date-based or excessive hints stop retries conservatively.
The default maximum accepted wait is 2 seconds. See [retry policy](retry-policy.md).

Writes and the raw SDK `execute` always send once. A trace failure cannot trigger
a retry or erase an accepted/applied write. Cancellation propagates; cancellation
during backoff does not invent a request or trace entry. Bounds are per-page
attempt and delay bounds, not an overall wall-clock deadline. The native HTTP
timeout still defaults to 30 seconds per attempt.

Every actual HTTP attempt retains the command's `operation_id` and a monotonically
increasing `attempt`, including retries on later pages. Each record captures that
response's safe `X-Request-Id`; it does not pretend the local operation ID is a
server log ID. Single-response DTO decode failures now retain status/request ID.
Multi-page aggregate DTO failures have no single attributable response ID, so
the caller uses the recorded attempts without assigning the error to the last page.

## Offline traces

```sh
moon run cmd/main -- meta --host https://moonhub.example --trace attempts.jsonl --json
moon run cmd/main -- trace list --trace attempts.jsonl --json
moon run cmd/main -- trace show OPERATION_ID --trace attempts.jsonl --json
moon run cmd/main -- trace list --trace attempts.jsonl --request-id SERVER_ID --status 503 --method GET --limit 20 --json
```

Trace commands construct no HTTP client and do not load token files, read stdin,
or require a host. `--trace PATH` selects the input explicitly. `trace show`
selects an exact operation ID; both commands support AND filters
`--operation-id`, `--request-id`, `--status`, `--method`, and `--path-prefix`.
An empty match is a successful empty result. The most recent 100 matching
attempts are returned by default, in original file order; `--limit` permits
1..1000. File append order is completion order, not a global timestamp order.

The JSON envelope is `{version:1,data:[...],scan:{scanned,matched,truncated,
incomplete_tail}}`. `data` contains only reconstructed version-1 trace metadata.
Queries reapply the same redaction and field allowlist; arbitrary extra fields,
bodies, headers and error messages cannot pass through. Offline reading cannot
discover an unknown credential previously embedded in otherwise valid metadata;
only use privately controlled files from the redacting recorder. SDK callers can
supply known `secrets` to `parse_trace_jsonl` or `native.read_trace`.

The native reader caps the file at 8 MiB, requires regular strict UTF-8 input,
refuses symlinks, and takes a shared advisory lock with a 30-second read/lock
timeout. The pure decoder additionally bounds lines to 16 Ki UTF-16 units and
the whole string to 8 Mi units. It scans and validates every complete line even
when the output limit is reached. A malformed complete line fails the entire
query without partial output. An unterminated final line is omitted and flagged,
even if its bytes form valid JSON, because an append completes with its newline.

Files are diagnostic history, not a durable transaction log. Rotation and
retention are explicit external responsibilities. Cooperating writers use an
exclusive advisory lock; the upstream filesystem API still lacks atomic
no-follow open, so parent directories must be trusted. Human diagnostics mark
truncation and interrupted tails; JSON carries those conditions in `scan`.

## Reuse and verification

No external dependency was added. Parsing and JSON reuse MoonBit core; HTTP,
TLS, scheduling, bounded waits, filesystem locking and subprocess fixtures reuse
`moonbitlang/async@0.21.3`. `moonbitlang/x@0.5.5` remains the process-exit adapter.
There are no project FFI declarations or fallback calls to curl/GitHub gh.
Public trace types stay in the root facade; the native filesystem adapter stays
under `internal/trace`; CLI formatting remains independent of storage.

The [executable smoke script](../scripts/operations_smoke.mbtx) launches the
release binary against loopback HTTP and reads real trace files. It covers all
four pipeline commands, exact If-Match, permission/stale-tag errors, no mutation
retries, transient GET recovery/exhaustion/disable, Retry-After, continuous
pagination attempts, offline filters, interrupted tails and malformed files.
[Compatibility cases](../testdata/compatibility/cases.json) cover additive v1
fields, unsupported versions, unknown states, numeric-vs-string IDs, exact Int64
IDs and status-authoritative errors. Prior read/mutation scripts remain regression
checks; none contacts a live account.

Reproduction commands and platform boundaries are in [release.md](release.md).
Reports are written to `_build/increment-{2,3,4}-smoke.json`. Generated reports
are local evidence; the scripts and fixtures are the reproducible inputs.

Verified locally on 2026-10-09, macOS arm64: **109/109 native tests**, **20/20
Increment 4 executable scenarios**, and **14/14 each** for the prior read and
mutation smoke scripts. Native release build and all-target typechecking pass
with warnings denied. This is local client/fixture evidence, not live MoonHub
or Linux/Windows runtime acceptance.
