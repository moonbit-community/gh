# Third-party code and runtime requirements

The GitHub mainline keeps project code and automation in MoonBit. It reuses the
toolchain core library and the pinned `moonbitlang/async@0.22.5` and
`moonbitlang/x@0.5.5` dependencies; their native FFI remains upstream code.
Bounded HTTP/1 encoding and decoding reuse the pure MoonBit
`ZSeanYves/MoonbitHTTP@0.7.0` `protocol/http1`/`core/types` packages. Only these codec packages
are imported; DNS and TLS remain on async 0.22.5. The HTTP codec is retained
because the CLI transport requires raw bytes, duplicate headers, arbitrary
methods, bounded framing, and explicit retry/redirect policy that the high-level
`async/http` client does not expose.

The pre-split MoonHub implementation used `moonbitstack/moonjson@0.4.0`
through `internal/wire_json` and its old smoke/candidate runners. Those are
preserved on `codex/moonhub-adapter`; the GitHub mainline has no remaining
consumer and removes that dependency. GitHub JSON handling uses the toolchain
core JSON package.

## MoonbitHTTP removal evaluation

The request-stream length check is only one part of the dependency's current
role. `internal/transport/raw_framing.mbt` also depends on its
incremental HTTP/1 response events for status-line parsing, repeated headers,
chunked bodies and trailers, 204/304/HEAD body rules, close-delimited bodies,
informational responses, and bounded header/body buffering. The `async/http`
high-level client stores headers in a `Map`, accepts a fixed method enum, skips
informational responses in `end_request`, and has no equivalent configurable
header/body limits. Its `enter_passthrough_mode` is a raw socket stream and does
not provide HTTP framing.

Therefore MoonbitHTTP is not an unused dependency and is not removed in the
core-parity migration. Ignoring the request length limit would silently remove
response and security guarantees required by `gh api`, including binary bodies,
duplicate fields and deterministic no-retry behavior. A later removal is safe
only after a project-owned `internal/http1` codec (or a reviewed vendored
subset) passes the existing framing and raw-transport fixtures on Native,
Wasm, Wasm-GC and JS where supported. That work should run as a dual-adapter
migration, compare byte-level behavior, then delete the MoonbitHTTP import and
license entry in one change.

## Distribution attribution

The source repository does not keep duplicate upstream license files. A future
GitHub distribution must obtain attribution from the actual installed
toolchain and resolved dependency sources, including:

- `moonbit-core-LICENSE.txt`: Apache-2.0 text from the core library shipped with
  the toolchain used to build the executable.
- `moonbit-core-NOTICE.txt`: the core library's complete NOTICE, including its
  retained third-party notices.
- `moonbit-async-LICENSE.txt`: Apache-2.0 text from async 0.22.5.
- `MoonbitHTTP-LICENSE.txt`: Apache-2.0 text from MoonbitHTTP 0.7.0.

Core, async and x sources attribute their code to International Digital Economy
Academy. The x 0.5.5 module declares Apache-2.0 and its used crypto/sys source
headers carry that license. The installed MoonBit native runtime C sources
also carry Apache-2.0 headers (Copyright 2026 International Digital Economy
Academy); the included Apache-2.0 text applies to those sources too. The
project does not bundle an SSL implementation or a C compiler.

The legacy MoonHub builder and its five-file attribution inventory remain on
`codex/moonhub-adapter`; that builder is removed from `master`. The current
mainline has no replacement packaging or manifest automation. Removing the
old tooling does not remove distribution notice obligations. Before any
release, review complete licenses and notices for the resolved dependencies,
compiler, platform, and linking configuration, and include them with the
artifact. Recheck those requirements whenever dependencies or the toolchain
change.

## HTTPS runtime dependency

The pinned async TLS adapter loads its SSL library lazily on the first HTTPS
request. A successful `--version`, a loopback HTTP smoke run, or a dependency
listing that only shows system libc does not establish that HTTPS works.

The installed `async/src/tls/openssl.c` tries these library names:

| Platform | Runtime lookup |
| --- | --- |
| macOS | `/usr/lib/libssl.48.dylib`, then `/usr/lib/libssl.46.dylib` |
| Linux | `libssl.so.3`, then `libssl.so.1.1`, then `libssl.so` |
| Windows | The separate upstream Schannel adapter uses Windows system TLS |

The OpenSSL adapter also checks version and required symbols after loading.
A different library installation path is not automatically discovered by this
version's macOS lookup. Do not promise that installing a separate SSL package
will fix an incompatible system without verifying the actual adapter behavior.

Before advertising a platform, run a controlled HTTPS request with system trust
and verify rejection of an invalid certificate. Record the actual OS, library
availability and trust configuration. Such runtime tests and live GitHub
acceptance remain independent gates in [release validation](release.md).
