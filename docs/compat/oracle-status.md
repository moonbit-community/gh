# Oracle evidence status

Recorded on 2026-10-16 for the `codex/github-compat` migration from baseline
`68b93e4`; branch policy updated on 2026-10-17. The complete migration snapshot
is preserved at `da3ef15` on `codex/moonhub-adapter`, while `master` continues
with only the GitHub implementation. This document records upstream reference
evidence and its limits. Complete core parity is still an acceptance target:
parser, requests, output, errors, tracing, controlled fixtures, and applicable
interactive behavior must pass for each claimed command.

## Mac authentication and deploy-key acceptance (2026-10-21)

The [OAuth continuation record](../development/handoff-20261021-oauth.md)
records real device and browser-callback OAuth, macOS Keychain store/read/delete,
and selected-account identity checks on the final local binary. Both deploy-key
success lifecycles now pass after the test PAT permissions were updated, with
successful cleanup. The same binary passed the 20-probe read-only differential
against v2.102.0. OAuth acceptance is a real lifecycle check, not a differential
claim for every auth interaction. The earlier complete write matrix remains
tied to its earlier binary; hosted CI and complete core parity remain open.

## Mac repair acceptance (2026-10-20)

The [Mac continuation record](../development/handoff-20261020-mac-repairs.md)
records the final local binary, checksum-verified v2.102.0 macOS arm64 oracle,
20 passing read-only differential probes, 28 passing repair cases with two
deploy-key success cases pending permission, and the existing write lifecycle
regression (59 passing, 10 skipped). Both write cleanups passed. The repair
matrix includes permission-denial output comparisons; these do not count as
successful deploy-key creation. Complete core parity and hosted cross-platform
CI for the uncommitted local changes remain unverified.

## GitHub-only branch validation (2026-10-17)

After preserving the complete provider snapshot at `da3ef15`, the GitHub-only
tree passed all four target checks with `--frozen --deny-warn` and all retained
tests: Native 155, Wasm 51, Wasm-GC 46, and JavaScript 51. The reduced counts
exclude the MoonHub packages and their tests, now preserved on the adapter
branch. The Native debug/release executable builds, root help/version smoke,
live-fixture runner self-test (no network), interface generation, formatting,
and diff whitespace checks also passed. The release C build emitted the
existing upstream async `thread_pool.c` unused-result warning.

This branch split does not rerun real-account tests; the earlier 20-probe
result remains tied to its recorded binary and does not establish acceptance
for the newly built executable.

## Executable provenance

The reference identifies itself as:

```text
gh version 2.102.0 (2026-09-30)
https://github.com/cli/cli/releases/tag/v2.102.0
```

The Linux amd64 release archive and its release checksum list were retrieved
through `ghproxy.net/https://github.com/cli/cli/releases/download/v2.102.0/`
after direct GitHub retrieval failed or produced a corrupted local archive.
The archive SHA-256 matches the release checksum list obtained through that
same proxy. This establishes checksum consistency; no independent signature or
attestation verification was performed.

| Artifact | SHA-256 |
| --- | --- |
| `gh_2.102.0_linux_amd64.tar.gz` | `bb766f710eef8ede859c18578c72c327597cd4c8a85b06001b1f3843c6019386` |
| Extracted `bin/gh` | `7469124f706944133d6a169691dd1c6c3511b12e85878d255e044e2948df4c9b` |

The verified local files used for this capture were:

- Executable: `/tmp/gh-2.102.0-proxy-44211/bin/gh`.
- Archive: `/tmp/gh_2.102.0_linux_amd64.proxy.tar.gz`.
- Checksum list: `/tmp/gh_2.102.0_checksums.proxy.txt`.

These temporary paths are execution evidence, not installed project
dependencies. Do not use the earlier `/tmp/gh-2.102.0/bin/gh`, which was
truncated, or `/tmp/gh-v2.102.0-fake`, which was only a runner mechanics fixture.
No upstream executable is committed, and production implementation must not
delegate its functionality to upstream `gh`.

## Reproduction and corpus

The [MoonBit runner](../../scripts/gh_oracle.mbtx) was successfully executed as:

```text
moon run --target native scripts/gh_oracle.mbtx -- /tmp/gh-2.102.0-proxy-44211/bin/gh testdata/gh-oracle/v2.102.0 7469124f706944133d6a169691dd1c6c3511b12e85878d255e044e2948df4c9b
```

To reproduce, supply your own checksum-verified pinned executable and use a
fresh output directory. The runner refuses nonempty output directories.

The [manifest](../../testdata/gh-oracle/v2.102.0/manifest.json) contains 275
snapshots, including 229 recursively discovered command-help cases. It records
literal argv, exit status, separate stdout/stderr filenames, captured flags,
and each stream's SHA-256. The generated
[inventory](../../testdata/gh-oracle/v2.102.0/inventory.md) makes the command and
flag surface reviewable.

Every capture uses an isolated working directory and private empty credential
configuration, with environment inheritance disabled. Locale and output settings
are fixed; update notices and telemetry are disabled. Processes receive literal
argv arrays through `@shell.Cmd`, with a 300-second timeout and 8-MiB output
bound; the local API probes have a five-second process bound. The optional
fixture mode and local API probes use only a synthetic token and scrub it
from captured output. Schema 2 explicitly records two normalizations: the
run's isolated HOME/config path becomes `<ORACLE_HOME>` (upstream Copilot help
embeds it), and the synthetic token becomes `<redacted>`. All other captured
text and whitespace is retained.

After adding these explicit normalizations and local API probes, a second
capture into `/tmp/gh-oracle-final-repeat-20261015-docs` compared byte-for-byte
equal to the checked-in corpus with `diff -qr` (exit 0). This verifies repeat
capture determinism on the current Linux host, not cross-platform equality.
`moon fmt scripts/gh_oracle.mbtx` and the scoped `git diff --check` also passed.
The runner build emits the upstream duplicate-import warning for
`moonbitlang/async/internal/c_buffer`; its execution exits successfully.

## Behavior confirmed by this capture

| Case | Observation |
| --- | --- |
| Empty root argv | Prints help; exit 0 |
| `issue` without subcommand | Prints command help; exit 0 |
| `api` without endpoint | Exit 1; stderr `accepts 1 arg(s), received 0` |
| `api --method` | Missing flag argument; exit 1 |
| `api -R owner/repo /user` | Unknown shorthand; exit 1 |
| `api --repo owner/repo /user` | Unknown flag; exit 1 |
| Unknown API flag plus `--help` | Still an argument error; exit 1 |
| `api /user` without credentials | Authentication required; exit 4 |
| `auth status` without credentials | Exit 1 |
| Fresh `alias list` | Includes `co: pr checkout` |
| `skills --help` | Real alias of `skill`; exit 0 |
| `send-telemetry --help` | Hidden command exists; exit 0 |
| `actions --help`, `accessibility --help` | Root help topics also resolve as command help; exit 0 |
| `licenses --help` | Third-party software notices, not repository license listing |

The pinned API help further states that repository placeholders resolve from
the current repository or `GH_REPO`, and field parameters become query
parameters when `--input` supplies the request body. The local refused-port
probes below confirm field query placement; repository placeholder resolution
still needs a git/environment fixture.

The unauthenticated `--slurp` without `--paginate` and combined
`--jq`/`--template` captures exit 4 because authentication is checked first.
They must not be used as proof that those option combinations are valid or
invalid after authentication. Separate authenticated local probes establish
the option validation below.

## Authenticated local API probes

The runner supplies a synthetic Enterprise token and never inherits user
credentials. The initial requested host `127.0.0.1:1` is itself invalid for
`--hostname`: all seven `api-probe-*` cases exit 1 with
`error parsing --hostname: invalid hostname` (the actual stderr surrounds the
flag name with backticks). It cannot establish option conflicts.

Repeating the same combinations with `--hostname 127.0.0.1` reaches local
option/file validation. Each following case exits 1 with empty stdout; the
first six include usage on stderr. Exact text is in the `api-loopback-*` files.

| Options | First stderr line |
| --- | --- |
| `--slurp` | `--paginate` required when passing `--slurp` |
| `--slurp --paginate --jq .` | the `--slurp` option is not supported with `--jq` or `--template` |
| `--silent --verbose` | only one of `--template`, `--jq`, `--silent`, or `--verbose` may be used |
| `--jq . --template x` | only one of `--template`, `--jq`, `--silent`, or `--verbose` may be used |
| `--paginate --input missing-file` | the `--paginate` option is not supported with `--input` |
| `-X POST --paginate` | the `--paginate` option is not supported for non-GET requests |
| `--input missing-file` | open oracle-input-does-not-exist.json: no such file or directory |

Three further cases use an existing synthetic `{}` input file and the absolute
endpoint `http://127.0.0.1:1/oracle-fixture`, keeping the port out of hostname
validation. Each exits 1 with connection refused; its diagnostic exposes the
attempted method and URL without a remote request:

| Options | Attempted request |
| --- | --- |
| `--input oracle-input.json` | `POST /oracle-fixture` |
| `--input oracle-input.json --method GET` | `GET /oracle-fixture` |
| `--input oracle-input.json --raw-field fixture=yes` | `POST /oracle-fixture?fixture=yes` |

The manifest marks `loopback_refusal_probes: true`. These are Linux local
transport-error observations, not successful HTTP fixture responses. Their
OS-specific refusal diagnostics are not cross-platform golden text.

## Evidence limits and deferred oracle capture

- The manifest explicitly records `network_fixture_executed: false`; no
  `GH_ORACLE_FIXTURE_HOST` was supplied. The upstream fixture case is skipped.
  The project uses separate loopback HTTP fixtures for REST/GraphQL response
  handling, streaming bytes, pagination, uploads, cache behavior, retries,
  cancellation, rate limits and authentication seams.
- No completed differential run compares the project executable with every
  upstream stdout, stderr, exit status or request shape. The checked-in oracle
  remains the pinned reference for help and local diagnostics; fixture tests
  provide the executable behavior evidence for the implemented core commands.
- Injected Native fixtures cover argv-only git, editor, browser and PTY/process
  adapters, including the Secret Service helper protocol through a fixture
  executable. Browser/editor command selection and OAuth device/web flows
  still require host acceptance and are intentionally not exercised against a
  real account.
- Cross-target test results must be reported by implementation validation;
  they are not implied by successful oracle capture. The original 139-test
  MoonHub migration baseline is preserved on `codex/moonhub-adapter`. The
  GitHub-only mainline no longer counts removed provider tests as its own
  acceptance evidence.

The separate [live fixture record](live-github-fixture.md) documents the
2026-10-17 20-probe read-only differential run. It applies to that tested
binary; splitting branches and rebuilding does not rerun live acceptance.

Commands enter the core parity count only after parser, SDK calls, output,
errors, trace, fixtures and applicable interactive/cross-target tests pass.
Generating help for a command is not command implementation. Deferred
integrations remain outside the core milestone and the full built-in parity
claim.
