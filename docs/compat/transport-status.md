# Raw transport status

The provider-neutral raw boundary is implemented in `raw_contracts.mbt`:

- `RawRequest` carries arbitrary token HTTP methods, origin-relative paths,
  repeated headers, byte bodies, or a single-use `RawBodyStream`.
- `RawHttpResponse` preserves status, repeated response headers, and bytes.
- `RawTransport` is an injected async boundary; it has no retry or redirect
  behavior.

`internal/transport/raw_native.mbt` provides `native_raw_transport`, backed by
the existing bounded HTTP/1 codec. It supports HTTPS and loopback HTTP,
`HEAD`/`OPTIONS`/custom methods, fixed or chunked request streams, binary and
empty responses, 1xx handling, `204`/`304` no-body semantics, response caps,
and cancellation through the configured timeout.

Native transport now selects `HTTPS_PROXY`/`https_proxy` for HTTPS and
`HTTP_PROXY`/`http_proxy` for HTTP, falling back to `ALL_PROXY`/`all_proxy`.
`NO_PROXY`/`no_proxy` supports `*`, domain boundaries, subdomain-only entries
starting with `.` or `*.`, and optional ports. `localhost` and IPv4 loopback
always bypass the proxy. Environment selection is captured when the transport
is constructed.

The bounded implementation reuses MoonbitHTTP URI parsing and upstream
`moonbitlang/async/http` CONNECT support. Unauthenticated HTTP(S) proxies with
DNS or IPv4 addresses are supported; SOCKS, proxy credentials, IPv6 proxy
addresses, and CIDR exclusions are outside the current boundary. Unsupported
proxy URLs fail with a static configuration error rather than exposing their
contents. A loopback test checks that origin Authorization is absent from
CONNECT and appears only inside the established tunnel. Real macOS OAuth
device/web flows passed with the host's HTTP proxy configuration; this is not
complete upstream proxy compatibility.

Targeted verification:

```text
moon check --target native internal/transport
moon test --target native internal/transport --filter 'raw transport*'
```

`master` retains only the raw transport. The former string-based
`native_transport`, legacy framing, and MoonHub-specific tests are preserved
on `codex/moonhub-adapter` at the pre-split snapshot `da3ef15`. New GitHub work
must use the byte-preserving raw boundary.
