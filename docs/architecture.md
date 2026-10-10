# Architecture

MoonHub `gh` provides a command-line client and reusable MoonBit SDK for MoonHub.
Its commands follow the shape of GitHub's `gh`, while its protocol and domain
model belong to MoonHub. Humans and AI agents use the same non-interactive
interface, predictable JSON output, and explicit failure semantics.

The client implements a proposed `/api/v1` contract. Contract fixtures and Native
CI validate the client; acceptance against a real MoonHub server remains pending.
The client does not import MoonHub's database, Web packages, or runner protocol.

## Scope

Supported operations include metadata and identity queries; repository reads;
Issue reads, creation, comments, closing and reopening; Merge Request reads,
creation, comments and merge submission; Pipeline reads, cancellation and
snapshot reruns; generic JSON API requests; and offline trace queries.

GitHub REST/GraphQL compatibility, full official `gh` command parity, GitHub
Actions compatibility, browser automation, interactive editors, OAuth/device
flow, request replay, and automatic update/distribution are outside this scope.
Token issuance and server authorization are MoonHub responsibilities.

## Request flow

```text
CLI arguments -> parsing and command policy -> typed MoonHub client
             -> origin-bound credentials and redacted transport
             -> MoonHub JSON API -> typed result or error
             -> deterministic stdout, stderr, and exit code
```

SDK callers can use the typed client directly or inject their own transport.
Concrete Native adapters compose upstream HTTP, files, and async primitives.
Project sources and automation remain MoonBit; upstream FFI is allowed.

## Package responsibilities

| Package | Responsibility |
| --- | --- |
| root | Provider-neutral requests, responses, errors, transport and trace contracts |
| `moonhub/` | MoonHub configuration, DTOs, typed operations, error decoding and mutation outcomes |
| `cli/` | Argument parsing, command dispatch, deterministic output and exit policy |
| `native/` | HTTP, environment/configuration, body input and trace-file composition |
| `cmd/main/` | Thin Native process entrypoint |
| `internal/auth/` | Origin-bound token resolution and validation |
| `internal/transport/` | Upstream Native HTTP adapter |
| `internal/trace/` | Native JSONL persistence and offline trace reads |
| other `internal/` packages | Focused parsing, pagination, retries and redaction helpers |
| `scripts/` | MoonBit executable fixtures and candidate verification |
| `testdata/` | Proposed API responses and compatibility cases |

Dependencies point inward from `cmd/main` to `native`, `cli`, `moonhub`, and root
contracts. Shared helpers stay in focused internal packages; public signatures
use types owned by the root, `moonhub`, or another deliberately public facade.
Business/DTO code does not read the environment, open files, or depend on Web
handlers. The concrete HTTP adapter is replaceable without rewriting commands.

Prefer suitable upstream/community libraries for general capabilities. Current
dependencies provide async HTTP/TLS, filesystem/process operations, JSON parsing
and cryptography. Project code owns MoonHub-specific policy. The bounded retry
loop exists because the pinned upstream exception retry helper does not consume
typed HTTP failures and `Retry-After`; see [retry policy](guides/retries.md).

## Server boundary

The proposed machine API uses Bearer credentials, JSON responses, and a fixed
versioned prefix. Browser cookies, CSRF forms and `/-/runner-api/v1` are separate
interfaces. Detailed definitions live in the [read](contracts/read-api.md),
[mutation](contracts/mutation-api.md), and [Pipeline](contracts/pipeline-api.md)
contracts. The [generic API command](contracts/api-command.md) preserves complete
JSON responses without applying typed DTO validation.

Server owners must confirm routes, field types, permissions, token lifecycle,
pagination and mutation semantics. `/api/v1` is the implemented client proposal,
not a claim that MoonHub already provides it. Before server implementation,
resolve its potential collision with namespace/repository paths; `/-/api/v1`
is an alternative consistent with MoonHub's reserved routing segment. Any change
requires coordinated client validation, pagination, fixtures and documentation.

Success envelopes use `{"version":1,"data":T}`. Lists have explicit bounded
pagination and same-origin next links. Unknown additive object fields are
ignored; incompatible types, versions and enum values fail explicitly.
Pipeline numbers use signed-Int64 decimal strings; Issue/MR numbers currently
have a positive Int32 limit that must be reconciled with server Int64 values.

HTTP status determines the primary error category. Only recognized codes and
sanitized correlation IDs are retained from server errors; arbitrary server
messages and response bodies never become diagnostics.

## Authentication and request policy

Credential precedence is explicit SDK token, `MOONHUB_TOKEN`, then an explicitly
selected config file. An invalid selected source fails without switching users.
Tokens are bound to the canonical complete origin, including non-default ports.
The transport and token must match the client's origin.

HTTPS is required for remote origins; HTTP is restricted to supported loopback
hosts. Redirects, alternate-host API requests and caller-supplied credential or
connection-framing headers are rejected. Injected transports are trusted
extensions and must honor their declared origin. See [SDK configuration](guides/sdk.md).

Typed GETs retry only bounded transient failures. Pagination and retries share
one operation ID and a continuous attempt sequence. Generic `api`, raw
`Client.execute`, and all mutations send once. A trace failure never causes a
network retry. Cancellation propagates instead of becoming an ordinary error.

## Writes and concurrency

Conditional operations require the exact strong ETag previously obtained from
the server. The client does not construct tags from version fields, silently
refresh them, or retry stale writes. Tags cover the complete selected
representation; the server compares and mutates atomically under the relevant
transaction/repository lock. Permissions and domain rules are independent checks.

Mutation outcomes distinguish `not_sent`, `rejected`, `applied`, `accepted`, and
`unknown`. A valid merge/cancellation receipt confirms acceptance, not eventual
completion. Transport loss or malformed success data can follow a committed
write; callers inspect server state before deciding to submit again.

## Observability

One redacted trace record describes each actual HTTP attempt: operation ID,
attempt number, method, path without query, HTTP status, duration, safe server
request ID and error category. Headers, bodies, body hashes and credentials are
not persisted. Later DTO decoding failure does not rewrite an HTTP trace.

Trace callbacks and serialization both sanitize metadata. A callback failure or
timeout sets `trace_failed` separately from the request result. Files use bounded
JSONL readers and cooperative locking. Their parent directories must be private;
the current upstream file APIs do not guarantee protection from hostile
concurrent path replacement. See [tracing](guides/tracing.md).

## Runtime and output

Native supplies the executable, HTTP/TLS, environment, files and process exit.
Linux x64, macOS arm64 and Windows x64 have hosted fixture verification. Portable
packages are also checked for Wasm, Wasm GC and JavaScript; Native-only packages
are excluded on those targets, so `--target all` is not a runnable cross-backend
CLI claim. A different host needs concrete adapters and its own acceptance.

JSON output is versioned and deterministic. Standard output carries results;
standard error carries diagnostics and trace warnings. Exit codes are 0 for
success, 1 for command/API/decode failure, 2 for input/configuration failure,
3 for authentication/permission failure, 4 for conflicts, and 5 for transport
failure. See [CLI usage](guides/cli.md) for examples and interpretation.

## Validation and delivery

Tests cover pure policy and injected transport, then executable fixtures exercise
real Native processes against loopback HTTP servers. Candidate tooling tests the
staged binary and records hashes, source/toolchain identity and execution evidence.
The [CI workflow](development/ci.md) runs separately on each supported platform.

Release candidates are unsigned, unpublished directories. Their manifests record
`published: false` and `live_server_verified: false`. Live MoonHub behavior, HTTPS
trust/invalid-certificate rejection, deployment permissions and formal distribution
remain separate [release acceptance requirements](development/release.md).

Historical implementation and review records are in [report/](report/README.md).
They preserve evidence for their recorded revisions and do not override current
contracts or establish acceptance for another build.
