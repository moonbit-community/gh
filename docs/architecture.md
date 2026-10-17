# Architecture

`master` contains the GitHub CLI and SDK. Its compatibility oracle is pinned to
GitHub CLI `gh v2.102.0`; parsing, output, exit status, authentication, and raw
REST/GraphQL behavior are measured against that release. Core parity is the
current acceptance target. The [oracle status](compat/oracle-status.md) and
[live fixture record](compat/live-github-fixture.md) distinguish verified cases
from outstanding acceptance work.

## Branch policy

The pre-split implementation is preserved at commit `da3ef15` on
`codex/moonhub-adapter`. That branch retains the MoonHub packages, native
adapters, fixtures, old contract documentation, and delivery scripts. The
GitHub mainline removes those provider-specific assets and dependencies while
retaining the shared raw transport and redaction infrastructure.

Continue GitHub work with `git switch master`. Use
`git switch codex/moonhub-adapter` to work on the preserved provider after
committing or otherwise saving local changes. Any later shared improvements
must be reviewed for each branch rather than restoring legacy provider code
to `master`. Future MoonHub integration follows its real `/-/api/v1` service,
after GitHub core parity; its former `/api/v1` proposal remains historical.
The client must never depend on MoonHub server database or Web packages.

## Scope

The first compatibility tier targets root/help/version, authentication and
configuration, `gh api`, repository/status, Issue/PR/discussion, releases,
Actions runs/workflows, search, org/project, credentials, and output filters.
It also requires Enterprise URL handling, pagination, redacted tracing, and
controlled Native adapters for git, editors, browsers, and credential storage.

Codespaces, Copilot, agent tasks, attestations, extensions, skills, telemetry,
and other release-specific integrations are separately deferred in the
[compatibility inventory](compat/gh-v2.102.0.md). An implemented request path
or matching help snapshot does not establish complete command compatibility.

## Request flow

```text
CLI arguments -> GitHub parser and policy -> raw/typed GitHub client
             -> origin-bound credentials and redacted transport
             -> REST or GraphQL API -> result or raw response/error
             -> stdout, stderr, and exit code
```

Project sources and automation remain MoonBit. Upstream Native FFI and
controlled system processes are allowed; the application never delegates its
implementation to an installed upstream `gh` executable. The pinned upstream
binary is used only by explicit oracle tooling.

## Package responsibilities

| Package | Responsibility |
| --- | --- |
| root | Provider-neutral byte requests, responses, errors, transport, and redaction contracts |
| `github/` | GitHub configuration, raw REST/GraphQL, pagination, rate-limit metadata, and tracing |
| `github_cli/` | GitHub parsing, repository identities, output filters, and exit-code policy |
| `native/` | Command execution, HTTP composition, credentials, local configuration, process adapters, and trace files |
| `cmd/main/` | Thin Native executable entrypoint |
| `internal/github_auth/` | Host normalization, credential precedence, and hosts configuration parsing |
| `internal/transport/` | Bounded Native HTTP/1 framing and raw transport |
| `scripts/` | Pinned upstream oracle capture and explicit live GitHub fixtures |
| `testdata/` | GitHub oracle reference corpus |

Command request mappings currently live in `native/github_business*.mbt`.
Reusable typed operations should move into a focused `github/operations/`
package as they are extracted; its absence is not hidden by this architecture.
Dependencies point inward from the entrypoint through native composition,
GitHub policy, and root contracts. Public signatures use facade-owned types.
Pure policy/DTO code does not read files, environment variables, or Web handlers.

Prefer suitable upstream/community libraries for general capabilities. The
current dependencies supply async I/O, TLS, filesystem/process operations,
cryptography, core JSON parsing, and bounded HTTP/1 codecs.
`gaato/github@0.10.0` remains a design reference, not a direct dependency.
The [dependency decision](development/dependencies.md) explains why the HTTP
codec remains necessary.

## Authentication and request policy

Credential precedence follows the fixed release: `GH_TOKEN`, then
`GITHUB_TOKEN` on GitHub.com; `GH_ENTERPRISE_TOKEN`, then
`GITHUB_ENTERPRISE_TOKEN` on Enterprise; then hosts configuration and the
Native credential backend. `GH_HOST` selects the default host. Tokens are
bound to the complete origin and excluded from argv, traces, Debug output,
ordinary logs, and errors. Explicit token-output commands have separate
synthetic-credential tests.

GitHub.com uses public REST/GraphQL origins; Enterprise uses REST `/api/v3`
and GraphQL `/api/graphql`. Browser HTML, cookies, and CSRF forms are not API
transports. Credential-bearing remote origins require HTTPS; HTTP is reserved
for explicitly configured loopback fixtures. Raw responses preserve status,
repeated headers, and bytes before output filtering or typed decoding.

Transport must not silently redirect or retry. CLI retries are disabled by
default; explicit SDK retry policy is bounded and read-only. Pagination and
retry attempts share operation identity. Observer failure does not change the
request result or trigger a retry. Cancellation stays distinguishable from an
ordinary failure.

## Writes and tracing

Commands preserve conditional headers and response receipts without inventing
ETags or retrying mutations. A success response is evidence for that operation,
not proof that a later merge or workflow completed. Lost transport or malformed
success data may follow a committed write; inspect state before submitting
again.

Each actual HTTP attempt records only sanitized provider, host, operation
name/ID, attempt, method, path without query, status, duration, request ID, and
error category. GraphQL adds a sanitized operation name and query fingerprint.
Headers, bodies, tokens, and raw query text are not persisted. Both callback
and serialization boundaries sanitize metadata; later decoding failures do
not rewrite HTTP attempt history. Keep trace parent directories private.

## Runtime and output

Native is the executable target for HTTP/TLS, files, processes, and exit codes.
Portable packages also run on Wasm, Wasm GC, and JavaScript. Passing portable
tests does not make native-only I/O packages or the executable portable. Each
supported host requires its own Native fixture and runtime acceptance.

Stdout carries results and stderr carries diagnostics. Exit code 0 means
success, 1 ordinary failure, 2 cancellation, and 4 authentication required.
Other nonzero statuses remain command-specific and must match the oracle.
See the [compatibility inventory](compat/gh-v2.102.0.md) for detailed behavior.

## Validation and delivery

[CI](development/ci.md) runs warning-denied checks, Native and portable tests,
Native builds, interface/format checks, and the live runner's offline self-test.
The self-test makes no real account request. Pinned help/error snapshots and
loopback fixtures are evidence for their exact cases. The separate live runner
requires explicit opt-in, a scoped token, and a dedicated test repository.

The recorded 20-probe read-only run predates the branch split. It does not
verify write lifecycles, nonempty resource behavior in every family, OAuth,
keyring, multiple accounts, full pagination, or complete interactive output.
A changed binary requires new evidence for its acceptance claim. Signing,
packaging, publication, and host-specific release requirements are tracked in
[release validation](development/release.md).
