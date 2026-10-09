# MoonHub `gh` Architecture

Status: **Increments 1–5 implemented; Increment 6 selects local Native delivery preparation; server and platform release gates remain open**

[Increment 1](increment-1.md) records the verified SDK workflow, config schema,
dependency reuse and runtime limits. This repository does not implement or
modify MoonHub's server endpoints.

[Increment 2](increment-2.md) records the native read CLI, output and pagination
behavior. [Read API contract](read-api-contract.md) fixes the proposed routes,
DTOs and fixtures for server review; a live MoonHub integration remains pending.

[Increment 3](increment-3.md) adds conditional writes and explicit mutation
outcomes. [Mutation API contract](mutation-api-contract.md) records source-grounded
concurrency, permissions and asynchronous merge semantics for server review.

[Increment 4](increment-4.md) adds pipeline operations, offline trace queries,
bounded read retries and compatibility fixtures. [Release documentation](release.md)
records reproducible validation and remaining server/platform gates. Increment
completion is not a claim that every first-release requirement below is complete.

[Increment 5](increment-5.md) completes the already listed generic JSON `api`
requirement, which the original Increment 0–4 breakdown did not assign. It
completes that client surface and its fixtures without expanding this repository
into the separate MoonHub server implementation.

[Increment 6](increment-6.md) selects route B from the
[scope proposal](increment-6-proposal.md): a verifiable local Native candidate,
fresh evidence tied to its executable bytes, and explicit platform handoff.
It changes only this client repository. The separate server implementation
remains future work; selecting this increment does not approve route A.

This document establishes the first implementation boundary for a MoonBit CLI
that serves MoonHub. It deliberately copies the useful command shape of
GitHub's `gh` without making GitHub's API, data model, or authentication rules
the center of the project.

## 1. Product intent

The executable gives humans and AI agents a small, deterministic interface to
MoonHub. It should make the operations already represented by MoonHub's domain
model available without scraping HTML pages or coupling a client to MoonHub's
SQLite database.

The first user-visible workflow is:

```text
CLI arguments
  -> command parser and policy
  -> MoonHub client
  -> redacting transport middleware
  -> /api/v1 machine API
  -> typed JSON result or typed error
  -> deterministic stdout/stderr and exit code
```

The CLI is named `gh` for command familiarity. The provider is MoonHub, and the
server contract is MoonHub-native. A future GitHub provider can be added behind
the same core contracts, but it is not a first-release acceptance condition.

## 2. Scope and acceptance

### First release

The first release must provide:

- MoonHub base URL and token configuration;
- `auth status` and the minimum token setup/status flow;
- repository view/list operations;
- issue list/view/create/comment/close/reopen;
- merge-request list/view/create/comment/merge, exposed as both `pr` and an
  optional native `mr` alias;
- pipeline list/view/cancel/rerun after the pipeline API contract is fixed;
- `api` as a generic JSON escape hatch for any documented MoonHub endpoint;
- redacted request traces that correlate retries and pagination;
- stable JSON output, human help, and documented exit codes;
- fake-transport tests and a local MoonHub end-to-end fixture.

### Explicit non-goals

The first release does not promise:

- full command or flag parity with the official GitHub CLI;
- GitHub REST or GraphQL compatibility;
- full GitHub Actions compatibility;
- browser HTML automation or CSRF form submission;
- OAuth/device-flow implementation before MoonHub defines it;
- direct access to MoonHub's database, internal runner protocol, or server
  implementation packages;
- a terminal UI, interactive editor, or complete table-formatting clone.

## 3. Repository layout

```text
.
├── contracts.mbt              # provider-neutral public request/error/trace types
├── origin.mbt                 # credential origin and relative-path policy
├── trace.mbt                  # metadata-only JSONL serialization
├── moon.pkg                   # root public contract package
├── moonhub/                   # MoonHub-native models and client configuration
│   ├── moon.pkg
│   └── models.mbt
├── native/                    # native SDK composition (HTTP, config, trace)
├── internal/auth/             # env and bounded explicit config-file loading
├── internal/transport/        # upstream async HTTP adapter
├── internal/trace/            # locked JSONL append and bounded offline reader
├── internal/pagination/       # bounded same-origin Link policy
├── cli/                       # command surface and deterministic presentation
│   ├── moon.pkg
│   └── help.mbt
├── cmd/main/                  # thin executable entrypoint
│   ├── main.mbt
│   └── moon.pkg
├── docs/                      # architecture and decision records
├── testdata/read-api/          # proposed v1 server response fixtures
├── scripts/read_smoke.mbtx     # real executable + loopback HTTP acceptance
├── scripts/mutation_smoke.mbtx # writes, If-Match, unknown outcomes, body input
├── scripts/operations_smoke.mbtx # pipelines, retries, trace queries, compatibility
├── scripts/api_smoke.mbtx      # generic JSON methods, input, headers and outcomes
├── scripts/release_candidate.mbtx # stages a Native candidate and fresh evidence
├── scripts/verify_candidate.mbtx # offline inventory/hash/evidence verification
├── scripts/release_smoke.mbtx   # candidate tooling failure-boundary regression
└── *_test.mbt                 # in-memory and local HTTP contract fixtures
```

Directories are introduced when a real responsibility needs them. Public values
stay in their facade packages; focused internal adapters own host capabilities.

## 4. Package responsibilities

### Root contract package

The root package owns types shared by providers and commands:

- `HttpMethod`;
- normalized `Request` and raw `Response`;
- `ApiError` categories that can become CLI exit behavior;
- `ApiFailure` metadata and origin-bound injected `Transport`;
- redacted `TraceRecord` entries.

These types must not know about MoonHub database rows, HTTP implementation
details, terminal rendering, or CLI argument parsing.

### `moonhub`

This package owns the MoonHub-facing public model:

- repository references;
- resource kinds;
- base URL and `/api/v1` configuration;
- typed DTOs as the API grows.

It owns endpoint naming and MoonHub-specific semantics. It does not import the
MoonHub server repository. The client will depend on an injected transport so
tests can run without a network.

### `cli`

This package owns:

- command and flag parsing;
- default repository resolution;
- JSON and human output modes;
- exit-code policy;
- help and diagnostics.

Stdout is reserved for command results. Diagnostics, trace notices, and
progress go to stderr. JSON output must have stable structure and ordering;
resource timestamps remain valid data. Increment 2 implements this policy for
the eight read operations, with fixed failure messages and explicit nulls.

### `cmd/main`

The executable remains thin. It obtains process arguments, calls the native
command facade, writes the returned stdout/stderr, and exits with its status.
It must not contain API calls or business rules.

### Native composition and internal packages

Add focused packages only when implementation requires them:

```text
native/              compose runtime adapters, return public SDK types
internal/transport/   upstream HTTP adapter (fake transports are test callbacks)
internal/auth/        token loading, storage, and redaction
internal/trace/       JSONL append (SQLite/filtering deferred)
internal/output/      stable JSON and human rendering
internal/commands/    command implementations if cli/ becomes too large
```

The implementation packages may depend on public contracts. Public packages
must not expose internal concrete types as part of their API.

## 5. Dependency direction

```text
cmd/main -> native -> cli -> moonhub -> root contracts
cli -> root contracts
native -> moonhub, internal/auth, internal/transport, internal/trace
moonhub -> internal/pagination -> root contracts
internal/auth -> moonhub -> root contracts
internal/transport, internal/trace -> root contracts
root contracts, moonhub -> internal/wire_json -> moonbitstack/moonjson
```

The transport implementation is injected into the MoonHub client. No package in
this repository imports MoonHub's `database`, `web`, or `runner` packages. This
keeps the CLI release cadence independent from the server and makes fake
transport tests cheap.

## 6. MoonHub machine API contract

MoonHub currently exposes browser HTML/form routes and a separate internal
Runner API. Those are not stable CLI contracts. The server work required for the
CLI is a proposed machine API mounted under `/api/v1`, while preserving existing
page URLs. Schemas/routes in this section are proposals to the server owner;
tests in this repository are client contract fixtures, not server acceptance.

The first endpoint families are:

```text
GET  /api/v1/meta
GET  /api/v1/user
GET  /api/v1/repos
GET  /api/v1/repos/{owner}/{repo}
GET  /api/v1/repos/{owner}/{repo}/issues
POST /api/v1/repos/{owner}/{repo}/issues
GET  /api/v1/repos/{owner}/{repo}/issues/{number}
POST /api/v1/repos/{owner}/{repo}/issues/{number}/comments
POST /api/v1/repos/{owner}/{repo}/issues/{number}/close
POST /api/v1/repos/{owner}/{repo}/issues/{number}/reopen
GET  /api/v1/repos/{owner}/{repo}/merge-requests
POST /api/v1/repos/{owner}/{repo}/merge-requests
GET  /api/v1/repos/{owner}/{repo}/merge-requests/{number}
POST /api/v1/repos/{owner}/{repo}/merge-requests/{number}/comments
POST /api/v1/repos/{owner}/{repo}/merge-requests/{number}/merge
```

Pipeline endpoints are added after their public read/write semantics are
written down. The internal `/-/runner-api/v1` protocol remains separate.

### Authentication

The CLI uses a MoonHub token in an `Authorization: Bearer <token>` header. The
token source order will be:

1. explicit SDK token argument (future CLI token input);
2. `MOONHUB_TOKEN` environment variable;
3. the user's local MoonHub config file.

Increment 1 accepts an explicit config path and versioned JSON containing
canonical origin keys; there is no implicit global path or credential writer.
The SDK resolves explicit > environment > file, with no fallback after an
invalid selected source. Tokens are bound to a complete origin including its
port. Client construction verifies transport and credential origins agree.
Token creation/revocation remains server work. A later CLI should read explicit
tokens from stdin rather than requiring a secret in argv. Tokens must never
appear in diagnostics or trace files.

### JSON errors

Every machine endpoint should use a versioned envelope:

```json
{
  "version": 1,
  "error": {
    "code": "not_found",
    "message": "repository does not exist"
  },
  "request_id": "..."
}
```

The CLI maps status classes consistently: authentication failures, permission
failures, invalid input, conflicts, transport failures, and server failures
must remain distinguishable to an AI caller.

Increment 1's SDK maps by HTTP status even for malformed/HTML error bodies.
It reads recognized v1 codes and safe correlation IDs, discards server message
text, and never treats redirect responses as success. 412 is a conflict;
429 is rate limiting. Raw successful response bodies remain available to the
caller; typed resource decoding belongs to Increment 2.

### Pagination and concurrency

List endpoints begin with `page` and `per_page` query parameters and return
GitHub-style `Link` headers. The client follows only documented next links.
Increment 2 freezes the supported subset in [the read contract](read-api-contract.md):
same origin and route, exactly the next page, unchanged page size, no extra query
parameters. Default reads fetch one page; explicit pagination is bounded by
20 pages (configurable up to 100) and 1,000 items. Errors discard partial data.

Increment 3 exposes the server's opaque strong ETag on individual reads and
requires the caller's exact `If-Match` for Issue close/reopen and MR comment/merge.
The client does not synthesize validators from version numbers or silently
refresh a stale tag. A stale precondition returns 412; a domain conflict returns
409. Issue comments append independently of the edit version and need no tag.

Source inspection showed that `edit_version` alone cannot be a strong ETag:
comments change `updated_at`, while merge jobs change status and merged SHA.
The server must cover the complete representation and compare/apply atomically,
refreshing MR branch comparisons under its repository lock. Its worker still
rechecks permissions, revisions, approvals, required checks and Git CAS.
Merge enqueue returns 202 `accepted`; it is not a completed merge.
These refinements and the seven POST routes are frozen in the proposed
[mutation contract](mutation-api-contract.md), pending server approval.

### Capability discovery

`GET /api/v1/meta` reports the protocol version and supported capabilities, such
as `issues`, `merge_requests`, `pipelines`, and `trace_request_id`. The CLI may
disable unsupported commands based on this response and should report the
capability name in a stable error.

## 7. Transport and trace contract

The MoonHub client accepts an injected transport. The transport receives a
normalized request and returns a raw response or a transport error. It must not
know how a command renders data.

The trace middleware records one entry for every actual network attempt:

```text
operation_id   groups a logical command across pagination/retries
attempt        actual attempt number
method/path    normalized method and path, with sensitive query values removed
status         response status when available
duration_ms    elapsed time when available
request_id     server X-Request-Id when returned
error_code     fixed transport or API category
```

Authorization, cookies, tokens, issue/MR bodies, source code, and arbitrary
query secrets are excluded by default. Mutation requests are never retried
blindly. Read requests may retry documented transient failures with a bounded
policy in Increment 4. Increment 1 never retries, follows redirects, or paginates.
Callers provide a logical operation ID and positive attempt number. Trace records
are sanitized before observers see them and again before JSONL encoding.

Sink failures/timeouts set `CallResult.trace_failed` while preserving the HTTP
outcome; callers must not retry a mutation because its trace failed. Cancellation
propagates during transport. Completion recording is protected from cancellation
and bounded to one second so an observer cannot erase an already received result.
An enclosing task group can still report its own cancellation, which never proves
a remote mutation was rolled back.
Completion-only logging cannot cover process crashes or partially written final
lines; it is diagnostic history, not a transaction log or replay system.

The existing MoonHub `repository_audit` table remains a domain-event audit log;
it is not reused as a network trace store. The first CLI implementation can use
JSONL, with SQLite deferred until filtering and retention requirements justify
it.

## 8. Runtime and portability

The executable targets Native first because it needs process arguments, local
configuration, credential storage, and network access. Provider-neutral types,
serialization, command planning, and fake transports should remain portable so
that a Wasm host can embed them later.

No project FFI is required for the first core. Native HTTP, secure credential
storage, or process integration may use an upstream MoonBit package with FFI
when the adapter boundary is explicit and testable.

Reuse is the default: this increment pins `moonbitlang/async@0.21.3` for
HTTP/TLS, async/cancellation and filesystem operations, and uses core JSON DTO
conversion/serialization and UTF-8 codecs. The implementation review pins
`moonbitstack/moonjson@0.4.0` for strict wire JSON parsing: it preserves numeric
spellings that core parsing rounds away. `internal/wire_json` owns this adapter
and exact bounded integer policy; no parser is implemented in project code.
The parser uses a depth budget of 128 on every platform (the root value is
depth zero). Hosted Windows validation exposed stack exhaustion at the previous
1024 setting. Excessive nesting is rejected through the existing error path;
SDK consumers do not need custom linker stack settings.
Increment 2 reuses `core/argparse` and pins `moonbitlang/x@0.5.5`
for native process exit rather than adding project FFI. The pins align with the inspected MoonHub source and passed the local
fixtures. Origins currently accept DNS/IPv4 names; IPv6 literals are deferred
because the upstream adapter's host resolver does not strip brackets. General
parsers, cryptography and network stacks must not be copied
into this repository when a suitable dependency exists. Dependency changes
require evidence for the API, target and behavior being used.

## 9. Output and exit behavior

The default human mode is concise and actionable. `--json` is the stable mode
for AI callers. Commands must not mix progress and JSON data on stdout.

The initial exit classes are:

```text
0  success
1  command or server failure
2  invalid command or arguments
3  authentication/permission failure
4  conflict or stale version
5  transport failure
```

The exact numeric table is a public CLI contract and must be tested before the
first release. Do not copy an official GitHub CLI number accidentally; choose
numbers that reflect MoonHub's categories and document them.

Increment 3 preserves these exits and adds a separate mutation outcome:
`not_sent`, `rejected`, `applied`, `accepted`, or `unknown`. Transport loss,
5xx, redirects and malformed success responses cannot prove that a write did
not happen. No mutation retries or hidden preflight GETs are performed.
Trace failure preserves the HTTP result. See [Increment 3](increment-3.md).

## 10. Testing strategy

Every API operation is tested at three levels:

1. pure decoding and command-planning tests using fixed JSON fixtures;
2. fake-transport tests for headers, pagination, retries, redaction, and errors;
3. local MoonHub HTTP tests covering auth, permissions, version conflicts, and
   response envelopes.

The first end-to-end path is `gh issue list --repo owner/name --json`, backed by
a fake transport and then by a local MoonHub fixture. Real remote accounts are
not required for ordinary tests.

## 11. Delivery increments

### Increment 0: foundation (complete)

- remove the generated template;
- establish package boundaries and public contracts;
- record the machine API and trace decisions;
- keep a runnable help command.

### Increment 1: transport and auth (complete)

- injected transport interface;
- MoonHub token loading and redaction;
- JSON error decoder;
- request trace recorder;
- fake-transport tests.

Includes a Native composition facade and loopback HTTP/file integration tests.
At that increment the executable remained a help entrypoint; Increment 2 adds
CLI commands and typed resource decoding. Live MoonHub acceptance, token
issuance and global credential storage remain pending.

### Increment 2: read-only operations (client and fixtures complete)

- `/meta`, current user, repository view/list;
- issue and merge-request list/view;
- stable JSON output and pagination;
- local MoonHub contract fixtures.

Includes a real executable smoke script over the committed fixtures and local
HTTP sockets. It does not constitute acceptance against MoonHub's server.
The server review boundary and reproducible commands are in [Increment 2](increment-2.md).

### Increment 3: mutations (client and fixtures complete)

- issue create/comment/close/reopen;
- merge-request create/comment/merge;
- ETag/If-Match conflict behavior;
- permission and error tests.

Includes bounded file/stdin body input, opaque ETags exposed by reads, validated
mutation receipts, async merge acceptance and unknown-outcome reporting. Current
fixtures test client handling of permissions/conflicts; real server enforcement
requires the separate API implementation and server integration acceptance.

### Increment 4: pipelines and operational tooling (client and fixtures complete)

- pipeline list/view/cancel/rerun;
- trace list/show/filter;
- bounded retry and request-id correlation;
- release documentation and compatibility fixtures.

Pipeline operations use the [source-grounded public API proposal](pipeline-api-contract.md).
Trace queries are offline; retries apply only to typed GETs and retain one trace
per attempt. [Increment 4](increment-4.md) and [release.md](release.md) distinguish
local executable evidence from outstanding first-release and server work.

### Increment 5: generic JSON API access (client and fixtures complete)

- `api PATH` with explicit GET/POST/PUT/PATCH/DELETE method selection;
- bounded JSON file/stdin input and validated custom headers, reusing existing
  upstream parsing, input, HTTP, auth and trace components;
- a public SDK operation that returns the complete JSON response, HTTP status,
  safe request ID, optional strong ETag and explicit write outcome;
- deterministic CLI output and fixed error diagnostics, with no implicit
  preflight, retry, redirect, pagination or response-header dump;
- fake-transport and real executable fixtures plus updated release evidence.

Paths stay relative to `/api/v1` and credentials stay bound to one origin. The
default method is GET; providing a body never changes the method implicitly.
All generic requests use one attempt, including GET, because this escape hatch
does not encode endpoint-specific replay policy. Structured commands retain
their existing read retries and typed DTO validation. Conditional headers remain
explicit; generic access does not infer resource concurrency rules.

The success `data` is the whole parsed JSON body, not an assumed versioned
resource envelope. A bodyless 204/205 maps to null. A generic HTTP success does
not verify a domain-specific schema or completion of asynchronous work. Server
API implementation, token issuance and real MoonHub acceptance stay separate
first-release gates; this increment introduces no browser or private-runner
fallback.

The exact command, input/header limits, success envelope and outcome rules are
in [api-command-contract.md](api-command-contract.md); reproducible local
acceptance is recorded in [Increment 5](increment-5.md).

### Increment 6: local Native delivery candidate (route B selected)

- a MoonBit `.mbtx` runner for serial checks, tests, Native release build and
  creation of a new candidate directory;
- the staged executable, LICENSE, usage and contract documentation, with
  version/help checks and all four CLI smoke suites run against that executable;
- explicit binary/report arguments for smoke scripts and fresh reports bound
  to the executable's path, byte size and SHA-256;
- a completion manifest recording actual OS/architecture, full toolchain,
  pinned dependencies, nullable Git revision, tracked/untracked state, file
  hashes and command exit results; it is written only after all checks pass;
- a bundled offline verifier for file inventory, hashes, eleven required checks
  and four reports, plus regression coverage for incomplete or altered
  candidates and protected output/report paths;
- reproducible platform handoff instructions and explicit remaining gates for
  TLS, filesystem behavior, cancellation and real MoonHub integration.

The candidate runner accepts an optional output directory that must not exist;
its default is a new directory under `_build/releases`. It never combines a new
candidate with historical smoke reports. The staged executable must pass the
read (14), mutation (14), operations (20) and generic API (18) fixture groups:
66 in total. Failed or interrupted runs do not receive a success manifest.
Every manifest records `published: false` and `live_server_verified: false`.
Step stdout/stderr and `runner-status.json` preserve diagnostics. The verifier
accepts a moved candidate by matching relative inventory and binary hashes;
it never executes the candidate binary or establishes publisher authenticity.

The first artifact is a directory. No suitable archive writer is already in
the pinned dependency set, so this increment does not implement an archive
format or require a system tar/zip command. Distribution signing, publishing,
registry changes, repository URL selection and the first Git commit are outside
this increment. Dependencies may use FFI; project automation remains MoonBit.

Only a run on its actual host verifies a runtime platform. Current historical
evidence is macOS arm64; Linux and Windows remain pending until their own
Native candidates and platform-specific checks pass. `--target all` provides
typechecking evidence, not cross-platform execution. Exact acceptance and this
increment's execution record are in [Increment 6](increment-6.md).

## 12. Decisions and reopening conditions

| Decision | Choice | Reopen when |
| --- | --- | --- |
| Product focus | MoonHub-first | A real second provider becomes an acceptance requirement |
| CLI shape | `gh`-like commands and JSON output | AI integration shows a better stable interface |
| Server boundary | New `/api/v1` JSON API | MoonHub adopts another versioned machine API |
| Auth | Bearer token, separate from browser sessions | MoonHub defines OAuth/device flow |
| Transport | Injected and traceable | A runtime requires a different host adapter |
| Concurrency | Opaque strong ETag/If-Match over current resource and revision state | Server changes its versioning model |
| Runtime | Native executable, portable core | A supported Wasm host supplies required capabilities |
| Trace storage | Redacted JSONL first | Retention/query requirements justify SQLite |

An implementation may reopen a decision only with new requirements, measured
runtime evidence, or a server contract change. A preference for a fashionable
pattern is not sufficient.

## 13. Unresolved contract questions

Before accepting writes against a real MoonHub server, its owner must settle
the following. Increments 3–4 implement the proposed client contracts and fixtures;
it does not claim that this server gate has been satisfied:

- server token creation, scopes, revocation, and expiration (local explicit JSON
  config format is defined in Increment 1);
- `/api/v1` response schemas and status codes;
- repository listing and permission filtering;
- Merge Request naming and merge-check/head-revision fields;
- pagination limits and Link format;
- ETag/version semantics;
- request ID generation and server log retention;
- pipeline public operations.

The smallest useful next evidence is a local `/api/v1/meta` endpoint, one
authenticated repository read, one issue read, one merge-request read, and
contract fixtures for their success and error responses.
