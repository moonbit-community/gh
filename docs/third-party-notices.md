# Third-party code and runtime requirements

The candidate keeps project code and automation in MoonBit. It reuses the
toolchain core library and the pinned `moonbitlang/async@0.21.3` and
`moonbitlang/x@0.5.5` dependencies; their native FFI remains upstream code.
Strict JSON parsing reuses the pure MoonBit `moonbitstack/moonjson@0.4.0`.

## Included attribution

The `licenses/` directory contains unmodified copies from the local dependency
and toolchain sources used for Increment 6:

- `moonbit-core-LICENSE.txt`: Apache-2.0 text from the core library shipped with
  `moon 0.1.20260920`, `moonc v0.10.14+7d59c7ec9`.
- `moonbit-core-NOTICE.txt`: the core library's complete NOTICE, including its
  retained third-party notices.
- `moonbit-async-LICENSE.txt`: Apache-2.0 text from async 0.21.3.
- `moonjson-LICENSE.txt`: Apache-2.0 text from moonjson 0.4.0. Its source headers
  attribute the parser to Copyright 2026 Leo Cheng.

Core, async and x sources attribute their code to International Digital Economy
Academy. The x 0.5.5 module declares Apache-2.0 and its used crypto/sys source
headers carry that license. The installed MoonBit native runtime C sources
also carry Apache-2.0 headers (Copyright 2026 International Digital Economy
Academy); the included Apache-2.0 text applies to those sources too. The
candidate does not bundle an SSL implementation or a C compiler.

These notices are a snapshot for the recorded toolchain and dependency versions.
When upgrading them, refresh the copied notices from the actual sources before
creating a distributable release. This local candidate does not claim an audited
notice inventory for every future compiler, platform or linking configuration.

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
