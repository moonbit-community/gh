# Third-party code and runtime requirements

The candidate keeps project code and automation in MoonBit. It reuses the
toolchain core library and the pinned `moonbitlang/async@0.21.3` and
`moonbitlang/x@0.5.5` dependencies; their native FFI remains upstream code.
Strict JSON parsing reuses the pure MoonBit `moonbitstack/moonjson@0.4.0`.
Bounded HTTP/1 encoding and decoding reuse the pure MoonBit
`ZSeanYves/MoonbitHTTP@0.6.0` `http1`/`types` packages. Only these codec packages
are imported; DNS and TLS remain on async 0.21.3. This published version fits
the existing runtime without an async upgrade or another TLS implementation.

## Candidate attribution

The source repository does not keep duplicate license files. The candidate
builder reads attribution from the actual installed toolchain and resolved
dependency sources and copies the complete texts into the candidate's
`licenses/` directory:

- `moonbit-core-LICENSE.txt`: Apache-2.0 text from the core library shipped with
  the toolchain used to build the candidate.
- `moonbit-core-NOTICE.txt`: the core library's complete NOTICE, including its
  retained third-party notices.
- `moonbit-async-LICENSE.txt`: Apache-2.0 text from async 0.21.3.
- `moonjson-LICENSE.txt`: Apache-2.0 text from moonjson 0.4.0. Its source headers
  attribute the parser to Copyright 2026 Leo Cheng.
- `MoonbitHTTP-LICENSE.txt`: Apache-2.0 text from MoonbitHTTP 0.6.0.

Core, async and x sources attribute their code to International Digital Economy
Academy. The x 0.5.5 module declares Apache-2.0 and its used crypto/sys source
headers carry that license. The installed MoonBit native runtime C sources
also carry Apache-2.0 headers (Copyright 2026 International Digital Economy
Academy); the included Apache-2.0 text applies to those sources too. The
candidate does not bundle an SSL implementation or a C compiler.

All five files remain required candidate contents and are covered by the
manifest's inventory and hashes. Missing upstream attribution fails candidate
creation; deleting repository copies does not remove attribution from delivery.
When upgrading dependencies or the toolchain, review the source locations and
notice requirements before creating a distributable release. The recorded
inventory does not establish attribution requirements for every future compiler,
platform or linking configuration.

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
availability and trust configuration. Such runtime tests and real MoonHub
acceptance remain the independent gates in [release.md](release.md).
