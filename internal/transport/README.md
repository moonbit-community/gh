# Native HTTP adapter

`native_transport` builds the injected root `Transport` over
`moonbitlang/async/http` for connection setup and the
`ZSeanYves/MoonbitHTTP@0.6.0` HTTP/1 codec. This package is Native-only and adds no project FFI or
system-command fallback. Upstream networking and TLS implementations may use FFI.

- Bind to one normalized HTTPS origin. HTTP is accepted only for loopback
  development. The upstream TLS client verifies certificates using system roots.
- Use origin-relative request paths. Reject absolute URLs, request-line/header
  injection, duplicate headers, and transport-owned framing/authority headers.
- Open one connection per attempt and always close it, including on cancellation.
  Do not follow redirects, retry, share cookies, or discover proxies implicitly.
- Send the supplied UTF-8 body with its byte-based Content-Length. The initial
  buffered JSON transport accepts UTF-8 responses only; binary/streaming download
  support is a later adapter concern.
- Apply a 30-second timeout to the whole attempt, including connection and body.
  Retain at most 8 MiB of response body by default, rejecting overflow without
  truncation. Both positive limits are configurable.
- Parse status/header/chunk/trailer lines under an 8 KiB limit. Headers and
  trailers each have a 64 KiB/100-field budget; the incremental byte buffer is
  capped at 16 KiB. A CR awaiting LF counts toward the line limit; lines through
  8191 bytes work with arbitrary fragmentation. Limits precede field retention.
- Request identity encoding and reject compressed responses. This keeps the cap
  over the received representation; decompression is not silently performed.
- Preserve cancellation and HTTP runtime errors for the client to classify safely.
  Adapter validation/limit failures carry static diagnostics, never request data.

The adapter enters the upstream client's public passthrough mode immediately
after connecting, before sending a request. Community codec events then drive
bounded response aggregation. Duplicate non-cookie fields are combined;
cookies and trailers are neither exposed nor reused. Informational/upgrade
responses and unsupported transfer encodings fail explicitly. TLS and DNS
remain upstream runtime responsibilities.

Tests use local ephemeral HTTP listeners. They cover every supported method,
authorization/header forwarding, UTF-8 request and response bytes, redirect
handling, the response size boundary, timeout, and rejection before connection.
They do not use remote accounts or validate a deployed MoonHub API.
