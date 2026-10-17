# Credentials and local commands implementation status

As of 2026-10-16. This records the authentication and local-command evidence
for the GitHub CLI v2.102.0 core-parity target. It does not claim that the
deferred integrations listed in the compatibility inventory are implemented.

## Implemented boundaries

- `internal/github_auth` resolves GitHub.com and Enterprise environment token
  precedence, normalizes/validates hostnames, selects REST/GraphQL URLs, and
  reads the active account from a bounded `hosts.yml` mapping subset.
- `native/github_credentials.mbt` resolves the environment before touching
  disk, including the explicit-file entrypoint. Missing files are anonymous
  configurations; directories, oversized files, malformed YAML and bad tokens
  become sanitized errors. Cancellation propagates.
- `native/github_local.mbt` implements `config get/list/set`, per-host
  settings, and `alias set/list/delete/import` with `--clobber`, `--shell`
  storage, `--all`, stdin and file input. Writes use 0600 temporary files and
  atomic rename in the same directory. Unrelated scalar/mapping settings and
  account credentials are preserved semantically; comments and original YAML
  presentation are not preserved.
- `native/github_auth_commands.mbt` implements `auth login`, `logout`,
  `refresh`, `setup-git`, `status`, `switch` and `token`. Status verifies
  `/user`; an existing token alone is not success. Authentication errors are
  sanitized, default token output is masked, and `--json hosts` authentication
  failures exit zero. Only an explicit `auth token` or `auth status
  --show-token` exports a credential.
- `native/github_auth_accounts.mbt` persists multiple accounts per host and
  rotates the active account for `switch` and `logout`. `auth status --json
  hosts` enumerates the stored hosts and accounts.
- `native/github_auth_store.mbt` exposes the `CredentialBackend` seam for an
  OS keyring. Successful keyring writes keep token values out of `hosts.yml`;
  tests use an in-memory backend and synthetic credentials. The same package
  provides asynchronous callbacks plus an argv-only Linux Secret Service
  adapter (`secret_tool_backend`); `GH_KEYRING_COMMAND` can point at a fixture
  executable for deterministic host tests.
- `native/github_auth_store.mbt` also exposes the `OAuthAdapter` seam. The
  adapter owns browser/device and clipboard policy and returns a token only on
  successful authorization; both synchronous and suspending native flows are
  accepted through `authorize_async`, and the CLI never puts a token in argv
  or trace data.
- `auth setup-git` invokes `git config` through the argv-only process adapter
  and installs a host-scoped `gh auth git-credential` helper.
- `gh api` and business commands opt into the default keyring adapter, so an
  account whose token is absent from `hosts.yml` can still authenticate. The
  environment token precedence remains unchanged.
- `configured_editor` resolves `GH_EDITOR`, `GIT_EDITOR`, `VISUAL`, `EDITOR`,
  then host config and `vi`; `run_configured_editor` appends its file path as a
  single argv element with a bounded timeout.

Entrypoints exclude the root command word from `args`:

```mbt
pub async fn github_config_command(args : Array[String], config_dir? : String) -> @github_cli.Output
pub async fn github_alias_command(args : Array[String], config_dir? : String, input? : String) -> @github_cli.Output
pub async fn github_auth_command(args : Array[String], environment? : @github_auth.Environment, config_dir? : String, transport? : @github.Transport, credential_backend? : CredentialBackend, oauth_adapter? : OAuthAdapter) -> @github_cli.Output

pub async fn github_auth_setup_git(args : Array[String], environment : @github_auth.Environment, runner? : async (Array[String]) -> Result[NativeProcessResult, ProcessAdapterError]) -> @github_cli.Output
```

The optional directory, environment and transport inputs are embedding/test
boundaries, not CLI flags. Tests use temporary directories, fake credentials
and injected transports, never user credentials or real accounts.

## Oracle evidence

The supplied `/tmp/gh-2.102.0-proxy-44211/bin/gh` executable was run in an
isolated configuration directory through an argv-based MoonBit `.mbtx`
runner. Observed and covered examples include default config output; empty
editor output; unknown-key warning/error; invalid git protocol; per-host
fallback; alias sorting, default `co`, duplicate refusal, `--clobber`, shell
quoting, import conflict skipping, deletion; anonymous auth token/status and
JSON status output. Native unit tests embed those expected observations.

The live-auth oracle probe against a local HTTP fixture timed out. Successful
auth status text/JSON is therefore validated with the project's loopback
transport and synthetic credentials rather than a live GitHub account. This is
appropriate for the core fixture gate: no test or CI job uses a real token.

## Validation

Passed during this slice:

```text
moon check --target native native --warn-list '-a' --no-render
moon test --target native native --warn-list '-a' --frozen
moon test --target native internal/github_auth --warn-list '-a' --frozen
```

The authentication tests cover environment and Enterprise precedence,
hosts.yml fallback, keyring-backed accounts, OAuth injection, account
switch/logout, setup-git argv, token masking and status enumeration. The root
integration pass owns whole-tree interface/format and cross-target verification.

## Boundaries and remaining limitations

- OAuth remains a host adapter because device/web authorization requires a
  browser, clipboard and callback policy. Without an injected `OAuthAdapter`,
  `--with-token` remains the deterministic local flow and interactive OAuth
  reports an unavailable provider. The adapter supports suspending browser or
  device flows without blocking the MoonBit runtime. Keyring lookup has a
  Secret Service default on native hosts and falls back cleanly when the helper
  is unavailable.
- Auth status success output is fixture-checked with synthetic credentials. A
  real GitHub account is intentionally never used in tests or CI.
- `--jq` and `--template` implement the supported deterministic formatter
  subset used by core commands; they are not a vendored full jq interpreter or
  the complete Go template runtime.
- `config clear-cache`, extension-aware alias validation/expansion and shell
  alias execution. Alias persistence never evaluates a shell expression.
- Complete YAML semantics. The parser supports block mappings, quoted and
  plain scalars, `{}` and common alias block scalars. Flow collections, YAML
  anchors/tags, complex keys and general YAML typing are rejected.
- Config file comments/layout and exact YAML serialization; local config
  writes preserve values rather than byte-identical source presentation.
- No `gaato/github` dependency or new process/library import was introduced.

This evidence covers the listed request paths and controlled fixtures.
Complete core parity, host-specific keyring/OAuth acceptance, and deferred
release integrations remain separate requirements.
