# Request tracing

Tracing records sanitized HTTP attempt metadata for debugging and correlation.
Enable it explicitly with `--trace PATH` or the Native SDK's `trace_path` option.
The parent directory must already exist and be privately controlled.

```sh
gh issue list --host https://moonhub.example -R team/demo --trace /private/attempts.jsonl --json
gh trace list --trace /private/attempts.jsonl --json
gh trace show OPERATION_ID --trace /private/attempts.jsonl --json
gh trace list --trace /private/attempts.jsonl --request-id SERVER_ID --status 503 --method GET --limit 20 --json
```

## Recorded metadata

One JSONL completion record describes each actual HTTP attempt:

```json
{"version":1,"operation_id":"operation-001","attempt":1,"method":"GET","path":"/api/v1/user","status":200,"duration_ms":12,"request_id":"request-001","error_code":null}
```

Pagination and typed-read retries share one operation ID and an increasing
attempt number. Locally rejected requests produce no network record. Waiting
between retries also produces no record. A later DTO or pagination decoding
error does not rewrite or duplicate the HTTP attempt; the SDK/CLI reports that
error separately.

Request IDs are safe IDs supplied by the server, not invented server log keys.
Correlation requires the server to return them and retain matching logs. The
local operation ID groups client work and need not appear in server logs.

The recorder removes queries and fragments, conservatively hides encoded path
segments and redacts known tokens in paths and IDs. IDs permit at most 128 ASCII
letters, digits or `._-`. Headers, request/response bodies, body hashes and
exception text are not recorded. Both callback preparation and JSONL
serialization sanitize metadata; optional fields are scalars or `null`.

A trace callback failure or a one-second timeout sets `trace_failed` separately
from the HTTP result. The CLI emits a stderr warning while preserving output
and exit code. It never retries a request because its trace failed. Completion
recording briefly shields cancellation within that bound; cancellation during
transport still propagates and an outer task group can report cancellation.

## Offline queries

`trace list` and `trace show` make no HTTP requests and do not load token files,
read stdin or require a host. `trace show` selects an exact operation ID. Both
support AND filters for `--operation-id`, `--request-id`, `--status`, `--method`
and `--path-prefix`.

The default is the most recent 100 matching records, in original file order;
`--limit` accepts 1–1000. File order is completion order, not a global timestamp
order. No matches is a successful empty result. JSON output has this shape:

```json
{"version":1,"data":[],"scan":{"scanned":0,"matched":0,"truncated":false,"incomplete_tail":false}}
```

`data` contains reconstructed version-1 metadata. Readers reapply the field
allowlist and redaction, so arbitrary extra fields, headers and bodies are not
passed through. They cannot identify an unknown credential embedded in otherwise
valid metadata. Use privately controlled files from the redacting recorder;
SDK callers can supply known `secrets` to `parse_trace_jsonl` or `native.read_trace`.

The Native reader requires a regular, strict UTF-8 file of at most 8 MiB,
rejects existing symlinks and takes a shared advisory lock with a 30-second
read/lock timeout. The pure decoder limits complete lines to 16 Ki UTF-16 code
units and the complete string to 8 Mi code units. It validates every complete
line even after the output limit is reached. Any malformed complete record
fails the query without partial output.

An unterminated final line is omitted and reported as `incomplete_tail`, even
when its bytes form valid JSON: the newline completes the append. `truncated`
indicates that the match count exceeds the output limit. Both conditions appear
in JSON scan metadata and human diagnostics.

## File safety and retention

Cooperating writers hold an exclusive advisory lock; readers hold a shared one.
Lock contention is cancellable. Native tests exercise locking and append/read
on Linux, macOS and Windows. POSIX files are created with mode 0600 and existing
files are tightened. Windows files inherit the parent directory's ACL; the
pinned adapter does not inspect or change ACLs.

The upstream file API lacks atomic no-follow open/fchmod support. Rejecting an
existing symlink does not protect against hostile concurrent path replacement;
control the parent directory and do not treat the trace path as an untrusted
shared location. `-` is not a stdout destination.

Trace files are diagnostic history, not a durable transaction audit log. A
crash can omit a completion record or leave a partial line. The recorder does
not rotate, truncate, delete or replay records; manage retention externally so
files stay within the reader's size limit. A missing record does not prove a
write was never applied. See [mutation outcomes](../contracts/mutation-api.md#mutation-outcomes-and-failure-handling).
