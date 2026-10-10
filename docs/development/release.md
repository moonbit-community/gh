# Release and compatibility

The module version is `0.1.0`. Candidate tooling builds a Native executable and
records validation evidence tied to that binary. Creating a candidate does not
publish a package, binary release or server deployment.
The CLI identifies itself as a MoonHub client and does not promise compatibility
with GitHub's `gh` command flags or API.

The module metadata snapshot is named `moon.mod.txt` so development tools do not
treat the delivery directory as a nested build project. The runner checks for
unlisted files before writing the completed manifest.

## Create a local delivery candidate

Use the [CI-pinned toolchain and core](ci.md), currently
`0.10.14+7d59c7ec9`, with the module's exact dependency versions:
`moonbitlang/async@0.21.3`, `moonbitlang/x@0.5.5`, and
`moonbitstack/moonjson@0.4.0`, plus `ZSeanYves/MoonbitHTTP@0.6.0`.
Run Moon commands sequentially because they share
the build lock. Each candidate captures its actual complete toolchain identity.
From the repository root:

```sh
moon update
moon run --target native scripts/release_candidate.mbtx
```

The default output is a new directory under `_build/releases`. To choose the
location, pass an output path that does not already exist. Its parent must
already exist; on macOS/Linux:

```sh
mkdir -p _build/releases
moon run --target native scripts/release_candidate.mbtx -- _build/releases/local-candidate-1
```

The runner checks Native and all-target types, runs Native tests sequentially,
builds the release binary, and stages it as `bin/moonhub-gh`
(`moonhub-gh.exe` on Windows).
It runs version/help and all four smoke suites against that staged file. The
candidate includes LICENSE, usage/contract documentation, a copy of
`scripts/verify_candidate.mbtx`, and an `evidence/` directory containing smoke
reports and per-step stdout/stderr logs. Smoke reports record the actual binary
path, byte size and SHA-256;
reports from unrelated earlier invocations are not accepted as fresh candidate
evidence.

`manifest.json` is the completion marker. The runner writes it only after all
checks and binary/file verification succeed. It records command results,
OS/architecture, toolchain, pinned dependencies, file hashes and Git state.
An unborn repository has a null revision; dirty or untracked source is recorded
explicitly. A manifest does not create a Git commit or identify unpublished
source as a reproducible release revision. Missing manifest means the candidate
is incomplete, even if a binary or some reports exist. Keep the failed directory
for diagnostics and rerun with a new output path.
`runner-status.json` records the current step and failure state independently
of the completion manifest. A null exit status denotes an unfinished, timed-out
or unstarted subprocess, not a passing check.

Every completed manifest records `published: false` and
`live_server_verified: false`. The candidate format is an output directory:
the pinned dependencies have no established archive writer. The
builder does not hand-write tar/zip or use a system archive fallback.
The candidate carries `licenses/` and [third-party notices](dependencies.md).
Those notes also document the pinned TLS adapter's runtime SSL loading paths;
loopback HTTP success and ordinary shared-library listings do not prove HTTPS
availability. Refresh notices when changing the toolchain or dependencies.

## Verify or move a candidate

From the source root:

```sh
moon run --target native scripts/verify_candidate.mbtx -- _build/releases/local-candidate-1
```

The verifier checks every listed file's SHA-256 and byte size, exact file
inventory, all eleven required zero-exit checks (including the verifier's own
compilation), and the four smoke reports'
binary identity and expected counts. It rejects missing/extra files, links,
incomplete candidates and mismatched evidence. It does not execute the binary.
Verification remains valid after moving the whole candidate: relative inventory
and hashes are authoritative, while report paths retain the original execution
location. From the moved candidate's root, use its bundled script:

```sh
moon run --target native --target-dir ../gh-verifier-build scripts/verify_candidate.mbtx -- .
```

Keep the verifier's build cache outside the candidate using `--target-dir`.
Otherwise Moon creates `scripts/_build` inside the candidate, and the strict
inventory correctly rejects the new files. Use an intact candidate copy if a
previous invocation already added a cache. The verifier does not silently ignore
extra build files.

This is an offline evidence check; cache the script's pinned MoonBit dependencies
before using an offline host. It does not contact MoonHub or prove publisher
identity. File hashes are consistency evidence, not a digital signature, and
cannot authenticate a candidate if its manifest and files are both replaced.

Run the candidate tooling regression separately from the source root:

```sh
moon run --target native scripts/release_smoke.mbtx -- _build/releases/local-candidate-1
```

It uses temporary copies to exercise damaged/missing manifests, changed files,
existing output protection, stale report handling and bounded JSON recursion.
All six verifier JSON inputs use depth 128; deeper arrays and objects are rejected
with a controlled error. The input candidate stays
intact; the tooling report is `_build/release-smoke.json`.

## Development checks and individual smoke runs

The same underlying checks can be run individually during development:

```sh
moon update
moon check --target native --deny-warn
moon check --target all --deny-warn
moon test --target native --strip -j 1
moon build --target native --release --deny-warn
moon run --target native scripts/read_smoke.mbtx
moon run --target native scripts/mutation_smoke.mbtx
moon run --target native scripts/operations_smoke.mbtx
moon run --target native scripts/api_smoke.mbtx
moon info
moon fmt . scripts/read_smoke.mbtx scripts/mutation_smoke.mbtx scripts/operations_smoke.mbtx scripts/api_smoke.mbtx scripts/release_candidate.mbtx scripts/verify_candidate.mbtx scripts/release_smoke.mbtx
```

The native release executable is
`_build/native/release/build/cmd/main/main.exe`, including on macOS. Each smoke
script accepts `[BINARY [REPORT]]` after `--`. With no arguments the release build
binary is used and reports default to `_build/read-smoke.json`,
`_build/mutation-smoke.json`, `_build/operations-smoke.json`, and
`_build/api-smoke.json`, respectively. An explicit
report parent directory must exist. For example, from the source root:

```sh
moon run --target native scripts/read_smoke.mbtx -- _build/releases/local-candidate-1/bin/moonhub-gh _build/read-recheck.json
```

An individual report is evidence for that invocation only; it does not finish
or rewrite the candidate manifest. Review generated `pkg.generated.mbti`
changes before creating a version tag; do not hand-edit them.

## Native platform handoff

The automated equivalent is [Native CI](ci.md), which runs the candidate and
release-tool verification on Linux x64, macOS arm64 and Windows x64. Its current
hosted execution evidence is recorded separately from historical local runs.

Hosted Native builds and fixture acceptance have passed on Linux x64, macOS
arm64 and Windows x64; the source revision, counts and artifact hashes are in
[the archived Native CI report](../report/native-ci-2026-10-10.md#execution-record).
Real-server acceptance, TLS certificate trust,
permissions and broader OS-specific cancellation still require separate
evidence. `moon check --target
all` checks portable core/SDK/CLI types; it does not run those platforms and does
not turn native-only packages into Wasm or JS executables. Ship a binary built
and checked for its actual OS/architecture, never rename a macOS binary as a
Linux or Windows artifact. Dependency FFI is allowed; project-owned code and
automation remain MoonBit.

On each target machine, install MoonBit and its Native C compiler prerequisites,
copy the complete source checkout, and run from that checkout. Preserve the
candidate directory and record any failed command before continuing. These are
separate native executions, not cross-compilation instructions:

macOS arm64, using its native terminal:

```sh
moon update
mkdir -p _build/releases
moon run --target native scripts/release_candidate.mbtx -- _build/releases/macos-arm64-candidate-1
./_build/releases/macos-arm64-candidate-1/bin/moonhub-gh --version
shasum -a 256 _build/releases/macos-arm64-candidate-1/bin/moonhub-gh
```

Linux, using a terminal on the intended deployment architecture:

```sh
moon update
mkdir -p _build/releases
moon run --target native scripts/release_candidate.mbtx -- _build/releases/linux-native-candidate-1
./_build/releases/linux-native-candidate-1/bin/moonhub-gh --version
sha256sum _build/releases/linux-native-candidate-1/bin/moonhub-gh
```

Windows, using PowerShell with the Native toolchain on `PATH`:

```powershell
moon update
New-Item -ItemType Directory -Force _build/releases
moon run --target native scripts/release_candidate.mbtx -- _build/releases/windows-native-candidate-1
& .\_build\releases\windows-native-candidate-1\bin\moonhub-gh.exe --version
Get-FileHash .\_build\releases\windows-native-candidate-1\bin\moonhub-gh.exe -Algorithm SHA256
```

Compare the printed hash with the manifest and smoke binary identity. The
candidate runner computes its own hashes with upstream MoonBit crypto; the
commands above are optional independent review tools. Directory names do not
assert platform support: use the actual manifest OS/architecture and successful
evidence. The hosted results cover the recorded runners and fixtures; use these
commands to validate other deployment hosts or architectures.

The 66 smoke groups use loopback HTTP and disposable local files. They do not
verify live TLS or every OS-specific filesystem behavior. Before advertising a
platform, attach separate results for system certificate trust and rejection of
an invalid certificate; concurrent trace locking; restrictive config/trace
permissions or Windows ACLs; file/stdin EOF and Unicode paths; and interrupting
in-flight reads/writes without accidental retries. An interrupted write can
still have committed remotely. Use controlled data and the agreed real API for
that last scenario; a killed fixture process cannot prove server rollback.

For local installation, copy the staged executable to a chosen directory under an
unambiguous name such as `moonhub-gh` and verify `moonhub-gh --version` and
`moonhub-gh --help`. Avoid silently overwriting an existing GitHub `gh`. A future
download should preserve the candidate's LICENSE, usage/contract documentation,
platform/toolchain coordinates, evidence and checksums. Distribution signing, release hosting, registry
publication and an update mechanism are not implemented here.

## Runtime contract for users and AI agents

- Set `MOONHUB_HOST` or pass `--host` with the complete origin. HTTPS is required
  except loopback HTTP. No browser sessions, redirects or cookie reuse.
- Set `MOONHUB_TOKEN` or select a private JSON file using `--config`. Tokens never
  belong in argv. See [token configuration](../guides/sdk.md#credentials-and-configuration) for precedence and
  the origin-scoped format. Setup currently means supplying an existing token;
  the client does not mint tokens, implement login/device flow or persist a
  global credential store. `auth status` verifies it through `/api/v1/user`.
- Use `--json`; stdout is the version-1 result, stderr is errors or trace warnings
  as JSON lines. Exit 0 means the HTTP operation succeeded; a merge/cancel can
  still be pending and a created rerun can later fail. Inspect `outcome`.
- Exit codes: 1 API/decode/command failure, 2 local input/configuration failure,
  3 authentication/permission failure, 4 conflict/stale precondition, 5 transport
  failure. Local malformed trace data uses 1; unreadable/invalid input uses 2.
- On `outcome: unknown`, inspect the resource before another explicit write.
  Do not treat a trace warning as permission to resubmit. Process interruption
  can prevent any structured result; absence of output does not prove rollback.
- Typed read retries allow at most three attempts per page by default
  for documented transient conditions. `--max-attempts 1` restores one attempt.
  All writes and raw `Client.execute` still use one attempt. See [retry policy](../guides/retries.md).
- Generic `api PATH` and SDK `Client.api` also always send once, including GET.
  They return the full JSON body, bypassing typed DTO validation, with explicit
  method and optional bounded file/stdin input. See [API command contract](../contracts/api-command.md).
- Select `--trace PATH` when needed. The file contains sanitized attempt metadata,
  excludes bodies and query strings, and needs a private parent directory. Query
  it offline with `trace list/show`. An 8 MiB scan cap makes rotation necessary
  for long-lived use; automatic deletion/rotation is not implemented.

## Compatibility fixtures

Wire contracts are proposed `/api/v1` contracts in
[read endpoints](../contracts/read-api.md),
[mutations](../contracts/mutation-api.md) and
[pipelines](../contracts/pipeline-api.md).
Committed fixtures under `testdata/read-api`, `testdata/mutations`,
`testdata/pipelines`, and `testdata/compatibility` drive SDK and executable tests.
They are not captured live responses and do not claim server compatibility.
`testdata/api` and `scripts/api_smoke.mbtx` cover generic requests;
those success fixtures deliberately include envelopes that typed DTO operations
would reject, because generic API access preserves the complete JSON body.

Additive object fields are ignored and only supported DTO fields are printed.
Missing supported optional fields are normalized to null. Unknown envelope
versions, wrong field types, unsupported enum values, lossy numbers and invalid
state/conclusion combinations fail closed. Run IDs use positive signed Int64
decimal strings; Issue/MR numbers retain their existing positive Int32 contract.
No automatic coercion, browser fallback or API-version negotiation is invented.
These schema rules apply to typed operations. The generic API command only
requires JSON syntax on ordinary 2xx responses, and returns every response
field. Its 204/205, strong ETag and HTTP error policies remain explicit in the
API command contract.
On a breaking server change, update the contract, fixtures, implementation and
CLI version together after agreeing the migration with the server owner.

Trace JSONL has a separate version-1 metadata contract. Readers ignore unknown
extra fields, reject unsupported versions and invalid complete records, and
report an incomplete tail. No timestamp, body, replay facility or server log
retention guarantee is implied. Request IDs correlate only when the server
actually supplies them and its log retention is separately established.

## Release acceptance requirements

Hosted Native fixture verification has passed on Linux x64, macOS arm64 and
Windows x64. These independent acceptance requirements remain:

1. Agree and implement MoonHub's public API, token issuance/scopes/revocation,
   permission filtering, paging, strong atomic ETags, request IDs and pipeline
   controls. Current MoonHub `672b8b5` exposes browser and private runner APIs,
   not the proposed public API. Client tests cannot prove server enforcement.
2. Run real local MoonHub acceptance with controlled data: reads, permission
   denial/revocation, stale writes, queued merges, cancellation races, immutable
   snapshot reruns, and failures after committed writes. Review the server gates
   in each contract document before any real-user rollout.
3. Complete deployment-specific TLS, permission and cancellation checks above,
   then choose and validate release signing, hosting and distribution. The
   repository is hosted at `moonbit-community/gh`; candidate creation records
   source identity and evidence but does not publish or sign a release.
   Native fixture success does not establish production readiness.

The minimum token setup flow is the documented environment/config workflow.
Future interactive authentication depends on an agreed server protocol and is
not required to invent a browser-based login workaround.
