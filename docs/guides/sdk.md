# MoonHub SDK

The SDK exposes typed MoonHub operations and replaceable request transport.
Its public API follows the proposed [read](../contracts/read-api.md),
[mutation](../contracts/mutation-api.md) and [pipeline](../contracts/pipeline-api.md)
contracts. Real MoonHub integration remains a separate acceptance requirement.

## Packages and runtime support

| Import | Purpose |
| --- | --- |
| `ZSeanYves/gh` | Requests, responses, transport, errors and trace metadata |
| `ZSeanYves/gh/moonhub` | Client, configuration, DTOs, operations, ETags and outcomes |
| `ZSeanYves/gh/native` | Native HTTP/TLS, environment/token-file and trace-file adapters |

Public contract and client packages are type-checked for Native, Wasm, Wasm GC
and JavaScript. The supplied network/filesystem composition and CLI are
Native-only. Other backends require host adapters and their own runtime tests;
all-target type checking does not establish equivalent runtime support.

See the generated interfaces for the complete API:
[root](../../pkg.generated.mbti), [MoonHub](../../moonhub/pkg.generated.mbti),
and [Native](../../native/pkg.generated.mbti).

## Use the Native client

Import the packages with aliases `@gh`, `@moonhub` and `@native`. Run the following
inside an async function; the server and file paths are placeholders:

```moonbit
let configured = @native.client(
  base_url="https://moonhub.example",
  config_path="/private/config/moonhub.json",
  trace_path="/private/logs/moonhub.jsonl",
)
match configured {
  Err(error) => println(error.code())
  Ok(client) => {
    let result = client.current_user(operation_id="operation-001")
    match result.value {
      Ok(user) => println(user.name_key)
      Err(failure) => println(failure.kind.code())
    }
    if result.trace_failed {
      println("request trace could not be recorded")
    }
  }
}
```

Client construction loads selected credentials and composes adapters without
opening a network connection. Typed methods cover metadata, current user,
repositories, issues, merge requests and pipeline runs. Caller-supplied operation
IDs correlate pages and attempts; use a distinct ID for each logical operation.

There are three request levels:

| Entry point | Result and request policy |
| --- | --- |
| Typed methods such as `current_user`, `issues`, `create_issue` | Validated DTOs, typed pagination or mutation results; only typed GETs can retry |
| `Client.api` | Complete parsed JSON value, HTTP metadata and optional mutation outcome; one attempt |
| `Client.execute` | Raw UTF-8 response and HTTP metadata with error decoding; one attempt |

For `api` and `execute`, request paths are relative to `/api/v1`, for example
`/user`. Do not include the prefix again. `Request::new` supports GET, POST, PUT,
PATCH and DELETE, with optional text bodies and caller-supplied headers. Both
entry points validate request paths and reject reserved or malformed headers.
The additional path, header-count, header-size and JSON-body limits belong to
`Client.api`; raw `execute` does not impose those size limits. See the
[API contract](../contracts/api-command.md).

## Credentials and configuration

Native credential precedence is explicit `token=...`, `MOONHUB_TOKEN`, then the
file selected by `config_path=...`. An invalid or empty higher-priority source
fails without falling back; a selected higher-priority value avoids reading
the lower-priority file. No default config path is discovered, and the client
does not write tokens or provide login, issuance, refresh or revocation flows.

```json
{
  "version": 1,
  "hosts": {
    "https://moonhub.example": "replace-with-an-existing-token",
    "http://127.0.0.1:8080": "replace-with-a-local-test-token"
  }
}
```

Config keys are canonical complete origins: lowercase host, no default port or
trailing slash, and no path, userinfo, query or fragment. Non-default ports are
part of credential identity. Remote origins require HTTPS; HTTP is accepted for
`localhost` and `127.0.0.1`. The client currently accepts ASCII DNS names and IPv4,
not IPv6 literals. Config files are bounded to 64 KiB. Callers control file and
parent-directory permissions; the loader does not change them or use a keychain.

`Token` is opaque and has no `Debug`, `Show` or `ToJson` representation. Its
explicit `authorization()` method returns sensitive header text and should only
be used at the trusted transport boundary. Bearer characters and length are
validated. Client construction requires the token, transport and client origin
to match.

`moonhub.Client` itself reads no environment or files. For custom hosts, call
`resolve_token` with explicitly supplied sources and pass the resulting token
to `Client::new`.

## Inject a transport

Tests and alternative runtimes can supply an asynchronous send function. This
example runs inside an async function with the package aliases above:

```moonbit
let transport = @gh.Transport::new(
  origin="https://moonhub.example",
  send=_ => {
    @gh.Response::new(
      status=200,
      body="{\"version\":1,\"data\":{\"api_version\":1,\"server_version\":\"test\",\"capabilities\":[]}}",
    )
  },
)
match @moonhub.Client::new(
  config=@moonhub.ClientConfig::new(base_url="https://moonhub.example"),
  transport~,
) {
  Err(error) => println(error.code())
  Ok(client) => {
    let result = client.meta(operation_id="test-meta")
    match result.value {
      Ok(meta) => println(meta.server_version)
      Err(failure) => println(failure.kind.code())
    }
  }
}
```

`Client::new` also accepts `trace`, `clock`, `read_retry` and `retry_wait`.
The trace callback receives sanitized `TraceRecord` values. An injected clock
returns milliseconds as `Int64`; an injected retry wait accepts milliseconds.
These hooks keep timing and failure tests deterministic.

Injected transports are trusted extensions: they must honor their declared
origin, faithfully report responses and propagate cancellation. Client checks
cannot prevent a malicious send function from forwarding credentials elsewhere.

## Results, retries and cancellation

`ReadResult[T]` contains `value`, `trace_failed`, `pages`, `next` and `etag`.
Typed list methods optionally aggregate bounded pages and return no partial
typed success on failure. Typed GETs use three attempts per page by default;
`ReadRetryPolicy::new(max_attempts=1)` disables retries. See [retry policy](retries.md).

`MutationResult[T]` includes a separate `outcome`: `NotSent`, `Rejected`,
`Applied`, `Accepted` or `Unknown`. Conditional writes require a parsed strong
`EntityTag` returned by the server. No mutation, raw `execute` or generic `api`
call retries automatically. Transport loss or a malformed success response can
follow a committed write; inspect server state before another submission.

HTTP status controls error classification even if the error body is HTML or an
unknown envelope version. Known v1 error codes and sanitized request IDs provide
additional metadata; arbitrary server messages and exception text are not
displayed. Native cancellation propagates rather than becoming an ordinary HTTP
failure. Interruption does not imply rollback of remote work.

Trace failure is independent of the remote result. A failed or timed-out callback
sets `trace_failed`; it does not turn success into a transport failure or trigger
another request. See [request tracing](tracing.md).

## Native transport limits

Each HTTP attempt opens a connection, with a default 30-second timeout covering
connection, request writing and response reading. The default response body cap
is 8 MiB. `@native.client` accepts `timeout_ms` and `max_response_bytes` overrides.
Only identity-encoded, valid UTF-8 bodies are accepted. The incremental HTTP/1
codec limits status/header/chunk/trailer lines to 8 KiB excluding CRLF. Headers
and trailers each have a 64 KiB total and 100-field limit, including duplicate
fields and cookies. A trailing CR awaiting LF counts against the line limit,
so lines through 8191 bytes are accepted regardless of fragmentation.
Its pending byte buffer is capped at 16 KiB,
independently of the response body cap. Oversize inputs fail without truncation.

The adapter uses upstream TLS verification and does not follow redirects, reuse
cookies, load proxy environment settings, pool connections or provide custom CA
configuration. Binary streaming, compression and multipart uploads are outside
the current interface. Duplicate non-cookie headers are combined for the public
response; `Set-Cookie` fields and trailers are not exposed. Informational and
upgrade responses are rejected; unsupported transfer/content encodings and
ambiguous framing also fail.
Responses advertising a nonempty `204` body are rejected. An unframed `205`
keeps the existing immediate-empty behavior rather than waiting for EOF.

HTTPS runtime loading and certificate acceptance need verification on deployment
hosts; loopback HTTP tests do not prove them. See
[dependencies and TLS requirements](../development/dependencies.md).
