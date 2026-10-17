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

Targeted verification:

```text
moon check --target native internal/transport
moon test --target native internal/transport --filter 'raw transport*'
```

`master` retains only the raw transport. The former string-based
`native_transport`, legacy framing, and MoonHub-specific tests are preserved
on `codex/moonhub-adapter` at the pre-split snapshot `da3ef15`. New GitHub work
must use the byte-preserving raw boundary.
