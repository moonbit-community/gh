# Native HTTP adapter

`native_raw_transport` builds the injected root `RawTransport` over
`moonbitlang/async/http` for connection setup and the
`ZSeanYves/MoonbitHTTP@0.7.0` HTTP/1 codec. This package is Native-only and adds
no project FFI or system-command fallback. Upstream networking and TLS
implementations may use FFI.

- Bind to one normalized HTTPS origin. HTTP is accepted only for loopback
  development. The upstream TLS client verifies certificates using system roots.
- Use origin-relative request paths. Reject absolute URLs, request-line/header
  injection and transport-owned framing/authority headers. Preserve repeated
  caller headers and accept any valid HTTP method token.
- Open one connection per attempt and always close it, including on cancellation.
  Do not follow redirects, retry, share cookies, or discover proxies implicitly.
- Send raw bytes with their byte-based Content-Length. Reader-backed bodies
  support files and stdin; a declared stream length uses Content-Length and an
  unknown stream length uses chunked framing. Preserve response bytes without
  requiring UTF-8 or JSON.
- Apply a 30-second timeout to the whole attempt, including connection and body.
  Retain at most 8 MiB of response body by default, rejecting overflow without
  truncation. Both positive limits are configurable.
- Parse status/header/chunk/trailer lines under an 8 KiB limit. Headers and
  trailers each have a 64 KiB/100-field budget; the incremental byte buffer is
  capped at 16 KiB. A CR awaiting LF counts toward the line limit; lines through
  8191 bytes work with arbitrary fragmentation. Limits precede field retention.
- Request identity encoding by default. Keep any received content encoding and
  body bytes untouched, so the cap applies to the received representation and
  decompression is never performed implicitly.
- Preserve cancellation and HTTP runtime errors for the client to classify safely.
  Adapter validation/limit failures carry static diagnostics, never request data.

The adapter enters the upstream client's public passthrough mode immediately
after connecting, before sending a request. Community codec events then drive
bounded response aggregation. Response headers retain repeated fields, including
Set-Cookie; cookies are never stored or reused, and trailers are not promoted
into headers. Up to 16 informational responses may precede the final response.
HEAD, 204, and 304 responses preserve their bodyless behavior; protocol upgrades
and unsupported transfer encodings fail explicitly. TLS and DNS remain upstream
runtime responsibilities.

Tests use local ephemeral HTTP listeners. They cover standard and extension
methods, repeated headers, binary requests and responses, fixed and chunked
body streams, redirect handling, response size boundaries, cancellation, timeout,
and rejection before connection or stream consumption. They use no remote
accounts or credentials.
