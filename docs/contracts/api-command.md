# Generic JSON API command

The `api` command sends a JSON request through the configured MoonHub client.
It uses the same server routes and authentication as the typed commands and
does not promise GitHub compatibility. Typed commands remain preferable when a
resource has an existing DTO, pagination policy or domain-specific receipt.

## Invocation and request boundary

```text
gh api PATH [--method GET|POST|PUT|PATCH|DELETE]
            [--header 'Name: value']... [--input FILE|-]
            [--host ORIGIN] [--config FILE] [--trace FILE] [--json]
```

`-X` aliases `--method`, and `-H` aliases `--header`. The method defaults to GET;
supplying input never silently changes it. Method names are the uppercase values
shown above. Existing origin, token source precedence, timeout, response-size
and trace policies apply unchanged.

HEAD, OPTIONS, streaming, binary uploads, multipart/form bodies and arbitrary
credential headers are outside this command's scope.

`PATH` starts with `/`, is at most 4,096 ASCII characters including query text,
and is relative to the fixed `/api/v1` prefix. For example,
`/repos/team/demo/issues?state=open` addresses
`/api/v1/repos/team/demo/issues?state=open`. Supplying `/api/v1` or a path below
`/api/v1/` is rejected rather than adding the prefix twice. Absolute URLs,
scheme-relative URLs, fragments, backslashes, whitespace/control characters,
dot segments, encoded path separators and malformed percent escapes are
rejected by the existing request-path policy. Non-ASCII components must be
percent-encoded. Query text is retained for the request and removed from traces.
This command cannot address browser pages or the private runner API outside
the machine API prefix. `--repo`/`-R` is rejected; `MOONHUB_REPO` has no effect
on an explicit API path.

There is exactly **one network attempt**. The command never follows redirects,
Link headers or Retry-After, and never retries transport or HTTP failures.
`--max-attempts 1` is accepted; any other explicit value is rejected. The default
three-attempt policy for typed GET operations does not apply here. List paging
flags are not accepted: callers request a documented page in `PATH` explicitly.
This makes invocation count and mutation intent predictable for an AI caller.

`--input FILE` reads a regular file; `--input -` reads stdin. Input must contain
one valid UTF-8 JSON value within **80,000 bytes**, including whitespace. Reads
use the existing bounded, 30-second native body reader. Objects, arrays and
scalar JSON values, including `null`, are valid. Empty input, invalid UTF-8,
invalid JSON and oversized input fail locally. Wire JSON parsing uses a depth
budget of 128 on every platform, with the root value at depth zero; this applies
to request bodies and responses. GET cannot have input. Other
methods may omit a body; the client does not invent `{}`. After validating JSON,
the client sends the original text, preserving its number spelling, whitespace
and string escapes. Input does not come from an inline argv body flag.

Examples, assuming `MOONHUB_HOST` and a token are configured:

```sh
gh api /meta --json
gh api '/repos/team/demo/issues?page=2&per_page=30' --json
gh api /repos/team/demo/issues -X POST --input issue.json --json
gh api /repos/team/demo/issues/7/close -X POST \
  -H 'If-Match: "issue-7-v3"' --input close.json --json
```

The JSON files must match the documented endpoint schema. In particular, the
generic command does not impose typed issue/MR text limits or infer mandatory
If-Match headers. The caller must follow the endpoint's permissions,
preconditions and request schema. No preflight request obtains or refreshes an
ETag, and no command bypasses server authorization.

## Header policy

Headers are opt-in request metadata, not an alternate token configuration
mechanism. Each `--header` has a name, a colon and a value. Names are matched
case-insensitively and duplicates are rejected, including duplicate names with
different casing. The CLI splits at the first colon and strips surrounding
ASCII spaces from the value; it does not strip controls or whitespace from the
name. The request accepts at most **32 caller headers**; names are
1–128 ASCII letters, digits or hyphens, values are at most **4,096 printable
ASCII characters**, and the sum of name and value lengths is at most **8,192
bytes**. Since this subset is ASCII, these character and byte counts agree.
These limits concern caller headers, before client-managed headers are added.

The following names are reserved:

| Purpose | Forbidden caller headers |
| --- | --- |
| Credentials | `Authorization`, `Proxy-Authorization`, `Cookie`, `Cookie2`, `X-Api-Key`, `Api-Key`, `X-Auth-Token`, `X-Access-Token` |
| Routing and connection/framing | `Host`, `Content-Length`, `Transfer-Encoding`, `Connection`, `Upgrade`, `Expect`, `Proxy-Connection`, `Keep-Alive`, `TE`, `Trailer` |
| Proxy route and method overrides | `Forwarded`, every `X-Forwarded-*` name, `X-Original-URL`, `X-Rewrite-URL`, `X-HTTP-Method-Override`, `X-HTTP-Method`, `X-Method-Override` |

`Accept` and `Content-Type`, when supplied, must be exactly `application/json`.
The client supplies JSON Accept and, when there is a body, JSON Content-Type.
`Accept-Encoding` can only be `identity`; the native adapter sets identity
encoding in every case. Compression, multipart upload, form bodies,
alternate-host requests and caller-supplied credential headers are unsupported.

`If-Match`, when supplied, must parse as the existing bounded strong
`EntityTag`: one quoted opaque ASCII value, 2–256 characters including quotes.
Weak tags, `*`, tag lists and malformed tags are rejected locally. The exact
quoted tag is sent. Endpoint-specific non-reserved headers remain available
within the same limits.

## Success data and write outcomes

Any HTTP 2xx result must contain valid JSON, except that status 204 or 205
requires an empty body and becomes JSON `null`. A nonempty 204/205 response,
including whitespace or the literal `null`, is a decode failure. Empty
200/201/202 bodies and malformed JSON are also decode failures. The entire JSON
value is returned; it is not unpacked as a typed v1
envelope and no resource DTO is applied. For example, a future
`{"version":2,"data":...}` response remains usable through this command even
when the typed command rejects that version.

If present, a response ETag must be one valid strong tag. Invalid, weak or
repeated ETags produce a decode failure. Missing ETags are allowed. The output
request ID is the safe `X-Request-Id` header value: bounded ASCII metadata using
the existing token-redaction rule. Successful payload fields named
`request_id` remain payload data and are not promoted into trusted metadata.
There is no arbitrary response-header dump.

With `--json`, stdout contains one compact JSON value followed by a newline:

```json
{"version":1,"data":{"version":2,"data":{"future":true}},"status":200,"request_id":"req-api-1","etag":null,"outcome":null}
```

The outer `version` belongs to the CLI output contract. `data` is the entire
parsed server JSON value, including its own envelope if any; output is JSON
serialization, not byte-for-byte response passthrough. The output field order
is fixed; field contents and object order within `data` originate at the
endpoint. Consumers must not interpret this generic data as having passed the
typed SDK's field or enum validation.

For GET, `outcome` is null. For every other supported method, a valid HTTP 202
result has outcome `accepted`; every other valid 2xx result has outcome
`applied`. These describe HTTP acceptance, not completion of a merge, pipeline
or other asynchronous domain operation. Polling or follow-up reads are explicit
caller actions. Successful JSON data is endpoint content; it is not run through
a field whitelist or a credential scrubber. Diagnostic and trace redaction
remain separate from intentional endpoint data output.

Without `--json`, stdout is the complete JSON value formatted with two-space
indentation. Successful writes additionally print their HTTP status and outcome
to stderr; 202 explains that completion must be inspected at the endpoint.
No `--jq`, templates, raw fields or response-header rendering are provided.

## Failures and observability

Failures use the existing fixed diagnostic messages, HTTP categories and exit
codes: local input/configuration 2, authentication/permission 3, conflict/stale
ETag 4, transport 5, and other HTTP/decode failures 1. Error bodies are not
printed verbatim. A non-v1 or malformed error body still retains its HTTP
category; safe request IDs and recognized error codes follow the existing
decoder. No failure triggers a retry.

For an already parsed write command, local body/input/preflight failures report
`not_sent`; HTTP 4xx failures report `rejected`; transport loss, HTTP 5xx,
unexpected statuses and invalid successful responses report `unknown`.
Syntax/argument parsing errors retain the common invalid-argument schema and
do not claim a write outcome before a command has been resolved. GET failures
have no mutation outcome. An unknown write outcome requires inspecting server
state before explicitly submitting another request. Interruption or process
termination may prevent an output record and does not imply rollback.

Each actual HTTP attempt produces the existing metadata-only trace entry with
the invocation's operation ID, `attempt: 1`, method, redacted path, duration,
status and safe request ID when available. Request/response bodies, query text
and caller headers are not recorded. Trace sink failure adds an independent
stderr warning and preserves the response/outcome and exit code. Offline trace
queries work without changes.

## Implementation and contract fixtures

Implementation reuses the upstream `moonbitlang/core/argparse`, JSON and UTF-8
facilities, the existing async input reader, the single-attempt transport and
the existing trace/error/ETag machinery. Project code handles MoonHub client
policy; general capabilities use upstream packages, with no project FFI.

Fixture bodies are in [`testdata/api/`](../../testdata/api/):

| Fixture | Intended HTTP case |
| --- | --- |
| `future-envelope.json` | 200, preserve an unfamiliar envelope and nested fields |
| `created.json` | 201, whole JSON receipt with `applied` |
| `accepted.json` | 202, whole JSON receipt with `accepted` |
| `error-conflict.json` | 412, stale conditional request with `rejected` |
| `scalar-null.json` | 200, a valid scalar null body |
| `malformed.txt` | 2xx, incomplete JSON yielding a decode failure |
| `payload.json` | Input body with Unicode, whitespace and a large integer to preserve on the wire |

HTTP status, response headers and exact request expectations belong to SDK and
real-executable fixtures; they are not embedded into these response bodies.
The generic API command validates transport/output behavior against those local
fixtures. Production acceptance still requires the separate MoonHub server to
implement and approve `/api/v1`, token scopes, endpoint-specific authorization,
conditional writes and request-ID behavior.
