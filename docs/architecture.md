# Architecture

This branch is a GitHub-first MoonBit client and SDK. Its compatibility oracle is
the pinned GitHub CLI `gh v2.102.0`; command parsing, output, exit status,
authentication and raw REST/GraphQL behavior are measured against that release.
The core command tier described below is the current implementation milestone.
The [oracle status](compat/oracle-status.md) distinguishes captured upstream
evidence from fixture and acceptance limits.

The earlier MoonHub implementation is retained as a frozen provider alongside
the GitHub compatibility surface. `moonhub/` and its `/api/v1`
proposal contracts remain historical provider assets; they are not the GitHub
wire protocol and must not constrain the new `github/` client. MoonHub will be
reconnected later through the real `/-/api/v1` service contract without importing
the MoonHub server database, Web packages, or runner protocol.

## Scope

The first compatibility tier targets the `gh` root/help/version contract,
authentication and configuration, `gh api`, repository/status commands, Issue,
PR and discussion flows, releases, Actions runs/workflows, search, org/project
and credential-management commands, plus deterministic output filters. It also
requires a raw GitHub REST/GraphQL SDK, Enterprise URL handling, pagination,
redacted tracing, and Native process adapters for git, editors and browsers.

Codespaces, Copilot, agent tasks, attestations, extensions, skills, telemetry
and other release-specific integrations are tracked as deferred commands in the
[compatibility inventory](compat/gh-v2.102.0.md). They are outside core parity
and prevent a full built-in command parity claim until their own cases pass.
MoonHub behavior is outside this tier and is implemented later as a separate
provider.

## Request flow

```text
CLI arguments -> GitHub command parser and policy -> raw/typed GitHub client
             -> origin-bound credentials and redacted transport
             -> REST or GraphQL API -> typed result or raw response/error
             -> deterministic stdout, stderr, and exit code
```

The intended SDK supports raw calls, command-specific typed operations, and
transport injection. Concrete Native adapters compose upstream HTTP, files,
and async primitives.
Project sources and automation remain MoonBit; upstream FFI is allowed.

## Package responsibilities

| Package | Responsibility |
| --- | --- |
| root | Provider-neutral byte requests, responses, errors, transport and trace contracts |
| `github/` | GitHub configuration, raw REST/GraphQL calls and pagination |
| `github/operations/` | Planned command-specific typed operations |
| `github_cli/` | GitHub command parsing, dispatch, deterministic output and GitHub exit policy |
| `moonhub/` | Frozen MoonHub configuration, DTOs and legacy contract adapter; no GitHub types |
| `cli/` | Frozen MoonHub command assets retained during the provider migration |
| `native/` | HTTP, environment/configuration, body input and trace-file composition |
| `cmd/main/` | Thin Native process entrypoint |
| `internal/github_auth/` | GitHub host, environment and configuration credential policy |
| `internal/auth/` | Frozen MoonHub token resolution and validation |
| `internal/transport/` | Upstream Native HTTP adapter |
| `internal/trace/` | Native JSONL persistence and offline trace reads |
| other `internal/` packages | Focused parsing, pagination, retries and redaction helpers |
| `scripts/` | MoonBit executable fixtures and candidate verification |
| `testdata/` | GitHub oracle fixtures plus frozen MoonHub contract responses |

Dependencies point inward from `cmd/main` to `native`, `github_cli`, `github`,
and root contracts. The frozen MoonHub path remains an isolated adapter until it
is rebuilt against the real service API. Shared helpers stay in focused
internal packages; public signatures use types owned by the root, `github`, or
another deliberately public facade. Business/DTO code does not read the
environment, open files, or depend on Web handlers. The concrete HTTP adapter
is replaceable without rewriting commands.

Prefer suitable upstream/community libraries for general capabilities. Current
dependencies provide async HTTP/TLS, filesystem/process operations, JSON parsing
and cryptography. Project code owns GitHub command and provider policy; MoonHub
policy remains isolated in the frozen adapter. Its legacy bounded retry loop
exists because the pinned upstream exception retry helper does not consume typed HTTP
failures and `Retry-After`; see the frozen [MoonHub retry policy](guides/retries.md).
GitHub CLI retry remains disabled by default. `gaato/github@0.10.0` is a
design reference, not a first-version direct dependency; the current toolchain
and generated API boundaries must be assessed before any later adoption.

## Provider boundaries

GitHub requests use the public REST and GraphQL endpoints selected from the
configured host. The client does not use GitHub browser HTML, cookies or CSRF
forms as a transport. GitHub Enterprise uses its REST `/api/v3` and GraphQL
`/api/graphql` paths; `github.com` uses the public API origins. The generic
`gh api` command preserves response status, headers and raw bytes before output
filters or typed decoding.

The frozen MoonHub provider keeps its historical contract fixtures in the
[contract documents](contracts/read-api.md). Those documents describe a client
proposal, not GitHub behavior or a claim that a live MoonHub server has accepted
the routes. A later adapter must use the real `/-/api/v1` service API and must
not import MoonHub database/Web code.

## Authentication and request policy

GitHub credential precedence must follow the v2.102.0 oracle: `GH_TOKEN` then
`GITHUB_TOKEN` on GitHub.com; `GH_ENTERPRISE_TOKEN` then
`GITHUB_ENTERPRISE_TOKEN` on Enterprise; then the selected hosts configuration
and Native credential backend. `GH_HOST` selects the default host. An invalid
selected source fails without silently switching users. Tokens are bound to the
canonical complete origin, including non-default ports, and never enter argv,
trace, Debug output or ordinary diagnostics. Explicit token-output commands
are separately tested with synthetic credentials only.

HTTPS is required for credential-bearing remote origins; HTTP is reserved for
an explicitly configured loopback fixture. Transport must not silently follow
redirects or retry requests. Header validation and origin credential handling
must preserve pinned command behavior without allowing framing injection.
Retry is disabled by default so `gh api` remains predictable; callers may opt
into a bounded policy for typed
read operations. Pagination and retries should share one operation ID and a
continuous attempt sequence. A trace failure must not cause a network retry,
and cancellation must remain distinguishable from an ordinary failure.

## Writes and concurrency

Provider operations preserve conditional request headers and response receipts.
GitHub commands do not invent ETags, silently refresh credentials, or retry
mutations. MoonHub's stronger ETag and mutation-outcome rules remain local to
the frozen provider contracts and are not imposed on GitHub's API semantics.

Request outcomes distinguish local validation failure, rejected response,
accepted response, and unknown transport completion. A successful mutation
response does not claim that a later GitHub workflow or merge has completed.
Transport loss or malformed success data can follow a committed write; callers
inspect provider state before deciding to submit again. MoonHub's more specific
outcome names remain documented only in its frozen contract package.

## Observability

Each actual HTTP attempt must have one redacted trace record: provider, host,
operation name and ID, attempt number, method, path without query, HTTP status,
duration, safe server request ID and error category. GraphQL requires a
sanitized operation name and query fingerprint without storing the query.
Headers, bodies and credentials must not be persisted. Later DTO decoding
failure must not rewrite an HTTP trace.

Trace callbacks and serialization must both sanitize metadata. Observer failure
must be reported separately from the request result. The frozen MoonHub
persistence implementation uses bounded JSONL readers and cooperative locking;
its existing tests do not establish GitHub trace acceptance. Parent directories
must be private; the current upstream file APIs do not guarantee protection from hostile
concurrent path replacement. See the frozen [MoonHub tracing guide](guides/tracing.md).

## Runtime and output

Native is the executable target for HTTP/TLS, environment, files and process
exit. Linux x64, macOS arm64 and Windows x64 each need GitHub fixture acceptance;
historical MoonHub CI does not provide that evidence. Portable packages must
also pass Wasm, Wasm GC and JavaScript tests. Native-only packages are excluded
on those targets, so passing portable tests is not a runnable cross-backend
CLI claim. A different host needs concrete adapters and its own acceptance.

GitHub-compatible output must follow v2.102.0: standard output carries results;
standard error carries diagnostics and trace warnings; exit code 0 means
success, 1 ordinary failure, 2 cancellation, and 4 authentication required.
Other non-zero statuses remain command failures and are recorded by the oracle.
The frozen MoonHub adapter may retain its historical five-category policy while
it remains isolated. See the [compatibility inventory](compat/gh-v2.102.0.md)
for the exact oracle and links.

## Validation and delivery

Acceptance requires pure policy and injected transport tests, then executable
fixtures exercise real Native processes against loopback HTTP servers and pinned `gh` oracle
snapshots. Candidate tooling must test the staged binary and record hashes, source/
toolchain identity and execution evidence. The legacy [CI workflow](development/ci.md)
must be extended with GitHub acceptance on each supported platform.

Legacy MoonHub release candidates are unsigned, unpublished directories. Their
manifests record `published: false` and `live_server_verified: false`. Live MoonHub behavior, HTTPS
trust/invalid-certificate rejection, deployment permissions and formal distribution
remain separate [release acceptance requirements](development/release.md).

Historical implementation and review records are in [report/](report/README.md).
They preserve evidence for their recorded revisions and do not override current
contracts or establish acceptance for another build.
