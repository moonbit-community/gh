# GitHub CLI v2.102.0 compatibility oracle

This document fixes the behavior we measure for the GitHub-first branch. The
oracle is the released [`gh v2.102.0`](https://github.com/cli/cli/releases/tag/v2.102.0)
binary captured on 2026-10-15. The checked-in [corpus](../../testdata/gh-oracle/v2.102.0/manifest.json)
fixes its help, flags, and selected local behavior; online manual links are
explanatory references and may change. A later GitHub CLI
release may add commands or flags; it does not silently change this baseline.

The runner at [`scripts/gh_oracle.mbtx`](../../scripts/gh_oracle.mbtx) accepts a
path to a locally supplied v2.102.0 executable. It does not download a binary,
invoke a shell, use a user's credential files, or contact GitHub by default. It
captures version/help output, deterministic local diagnostics, and explicitly
bounded requests to a refused loopback port. Set
`GH_ORACLE_FIXTURE_HOST` to a caller-managed TLS Enterprise fixture host to
capture one `gh api` response; the host must already be configured for the
fixture and is never inferred from the network.

Run it with:

```text
moon run --target native scripts/gh_oracle.mbtx -- /absolute/path/to/gh-v2.102.0 [OUTPUT_DIR [EXPECTED_BINARY_SHA256]]
```

The output directory contains separate stdout/stderr files and a `manifest.json`
with literal argv, exit status, captured flag lines, and SHA-256 evidence.
Commands are discovered recursively from the pinned help output. The runner
requires the exact version prefix and boundary and, when supplied, the expected
binary SHA-256. It refuses a nonempty output directory. The current corpus has
275 snapshots, including 229 discovered command-help cases. Isolated HOME
paths and synthetic fixture tokens have explicit manifest normalizations. See
[oracle status](oracle-status.md) for provenance and acceptance limitations.

## Command inventory

The following top-level commands are the checked v2.102.0 inventory. Each is
invoked with `--help` by the oracle. `help` and `version` are included as root
behaviors even though they are not subcommands in every help rendering.

| Core parity tier | Commands |
| --- | --- |
| Root and local policy | `help`, `version`, `completion`, `config`, `alias` |
| Authentication and API | `auth`, `api` |
| Repository and status | `repo`, `status`, `browse` |
| Collaboration | `issue`, `pr`, `discussion`, `label`, `search` |
| Releases and Actions | `release`, `run`, `workflow`, `cache`, `actions` help topic |
| Organization and planning | `org`, `project`, `ruleset` |
| Credentials and artifacts | `gist`, `gpg-key`, `ssh-key`, `secret`, `variable`, `licenses` |
| Root-only behavior | `gh` with no arguments, `--help`, and `--version` |

These commands are the first implementation target. A command counts as core
parity only when its parser, request/response behavior, stdout/stderr, exit
status, trace fields, and fixture/golden cases agree with this release.

The following release-specific integrations are tracked separately and remain
deferred until their own oracle cases pass:

| Deferred integration | Command |
| --- | --- |
| Codespaces | `codespace` |
| Copilot | `copilot` |
| Agent tasks | `agent-task` |
| Artifact attestations | `attestation` |
| Extensions | `extension` |
| Skills | `skill`, with the real alias `skills` |
| Telemetry | `send-telemetry` |
| Preview/accessibility helpers | `preview`, `accessibility` |

The pinned executable accepts `skills --help` and the hidden
`send-telemetry --help`, both with status 0. `actions` and `accessibility` appear
as root help topics and also resolve with `--help`; their help behavior is
captured rather than treated as unknown commands. These observations do not
establish the behavior of their network or interactive integrations. MoonHub commands are not
part of this table; they belong to the frozen provider and will use the real
`/-/api/v1` service in a later adapter.

The release inventory fixes the subcommand spellings below. Nested commands
include `codespace ports forward` and `repo deploy-key add`; project item
listing is the hyphenated `project item-list`, not `project item list`:

| Command family | v2.102.0 subcommands |
| --- | --- |
| `agent-task` | `create`, `list`, `view` |
| `alias` | `delete`, `import`, `list`, `set` |
| `attestation` | `download`, `trusted-root`, `verify` |
| `auth` | `login`, `logout`, `refresh`, `setup-git`, `status`, `switch`, `token` |
| `cache` | `delete`, `list` |
| `codespace` | `code`, `cp`, `create`, `delete`, `edit`, `jupyter`, `list`, `logs`, `ports`, `rebuild`, `ssh`, `stop`, `view` |
| `config` | `clear-cache`, `get`, `list`, `set` |
| `discussion` | `comment`, `create`, `edit`, `list`, `view` |
| `extension` | `browse`, `create`, `exec`, `install`, `list`, `remove`, `search`, `upgrade` |
| `gist` | `clone`, `create`, `delete`, `edit`, `list`, `rename`, `view` |
| `gpg-key` / `ssh-key` | `add`, `delete`, `list` |
| `issue` | `close`, `comment`, `create`, `delete`, `develop`, `edit`, `list`, `lock`, `pin`, `reopen`, `status`, `transfer`, `unlock`, `unpin`, `view` |
| `label` | `clone`, `create`, `delete`, `edit`, `list` |
| `org` | `list` |
| `pr` | `checkout`, `checks`, `close`, `comment`, `create`, `diff`, `edit`, `list`, `lock`, `merge`, `ready`, `reopen`, `revert`, `review`, `status`, `unlock`, `update-branch`, `view` |
| `preview` | `prompter` |
| `project` | `close`, `copy`, `create`, `delete`, `edit`, `field-create`, `field-delete`, `field-list`, `item-add`, `item-archive`, `item-create`, `item-delete`, `item-edit`, `item-list`, `link`, `list`, `mark-template`, `unlink`, `view` |
| `release` | `create`, `delete`, `delete-asset`, `download`, `edit`, `list`, `upload`, `verify`, `verify-asset`, `view` |
| `repo` | `archive`, `autolink`, `clone`, `create`, `delete`, `deploy-key`, `edit`, `fork`, `gitignore`, `license`, `list`, `read-dir`, `read-file`, `rename`, `set-default`, `sync`, `unarchive`, `view` |
| `ruleset` | `check`, `list`, `view` |
| `run` | `cancel`, `delete`, `download`, `list`, `rerun`, `view`, `watch` |
| `search` | `code`, `commits`, `issues`, `prs`, `repos` |
| `secret` | `delete`, `list`, `set` |
| `skill` | `install`, `list`, `preview`, `publish`, `search`, `update` |
| `variable` | `delete`, `get`, `list`, `set` |
| `workflow` | `disable`, `enable`, `list`, `run`, `view` |

This table is release reference evidence, not a claim that every command is
already implemented in this branch. The recursively captured
[inventory](../../testdata/gh-oracle/v2.102.0/inventory.md) and individual
`--help` snapshots remain the reference source for formatting and
flags; subcommands with network, browser, editor, git, or interactive behavior
also require Native fixture cases.

## Exit-status contract

The pinned reference is [captured `gh help exit-codes`](../../testdata/gh-oracle/v2.102.0/help-exit-codes.stdout):

| Code | Meaning |
| ---: | --- |
| `0` | Successful execution |
| `1` | Ordinary command or API error |
| `2` | Command cancelled by the user or context |
| `4` | Authentication is required |
| Other non-zero | An error specific to the command or host |

The compatibility CLI must keep stdout for command results and stderr for
diagnostics. It must preserve the exit status even when the response body is
JSON, binary, or an HTTP error. Local argument/configuration failures are
compared against the same oracle rather than mapped into the former MoonHub
five-category policy.

## `gh api` flag and request contract

The pinned reference is [captured `gh api --help`](../../testdata/gh-oracle/v2.102.0/api-help.stdout).
The first high-value command slice must cover the following flags and their
interactions:

| Flag | Meaning in v2.102.0 |
| --- | --- |
| `-X`, `--method METHOD` | HTTP method; defaults to `GET`, and switches to `POST` when fields or `--input` provide a body unless explicitly overridden |
| `-f`, `--raw-field KEY=VALUE` | Add an untyped string parameter; nested keys use the documented bracket form |
| `-F`, `--field KEY=VALUE` | Add a typed parameter; booleans, numbers, `null`, and `@file` follow the manual's conversion rules |
| `-H`, `--header KEY:VALUE` | Add a request header; duplicate headers remain observable to the transport/fixture |
| `--input FILE` | Read the raw request body from a file; `-` means stdin |
| `--hostname HOST` | Select the GitHub or Enterprise host for this request |
| `-i`, `--include` | Include the HTTP status line and response headers in stdout |
| `--allow-escape-sequences` | Allow terminal escape sequences in output |
| `--silent` | Suppress response output while retaining the command status |
| `--verbose` | Include the complete HTTP request and response diagnostics |
| `-q`, `--jq EXPRESSION` | Apply jq selection to JSON response output |
| `-t`, `--template STRING` | Render JSON through the Go template formatter used by `gh` |
| `--paginate` | Follow REST `Link` pages or GraphQL cursor pages until exhausted |
| `--slurp` | Wrap paginated JSON pages in one outer array |
| `--cache DURATION` | Cache a successful response for the requested duration |
| `-p`, `--preview NAME` | Add the documented preview media type to `Accept` |

The endpoint is a relative REST path such as `/repos/{owner}/{repo}/issues`; an
endpoint named `graphql` selects the GraphQL request form. `{owner}`, `{repo}`,
and `{branch}` placeholders resolve from the current repository or `GH_REPO`;
there is no `-R/--repo` flag on `gh api` in this release. `--field` and
`--raw-field` values are encoded according to the endpoint's request body rules,
while `--input` supplies an already encoded body; when `--input` is present,
field parameters are placed in the URL query instead. The implementation must keep
the original response status, repeated headers, and bytes available to output
and trace layers before applying `--jq` or `--template`.

Authenticated local oracle probes confirm that `--slurp` requires
`--paginate`; `--slurp` rejects `--jq`/`--template`; only one of `--template`,
`--jq`, `--silent`, and `--verbose` may be used; and REST pagination rejects
`--input` and non-GET methods. These are validated after authentication, so
unauthenticated cases can exit 4 first. `--hostname` rejects a host with a
port; an absolute endpoint URL can contain one. See the
[exact diagnostics and request observations](oracle-status.md#authenticated-local-api-probes).

## Configuration and authentication references

The v2.102.0 environment and host rules are documented in
[`gh help environment`](https://cli.github.com/manual/gh_help_environment) and
[`gh auth`](https://cli.github.com/manual/gh_auth). The compatibility order is:

1. `GH_TOKEN`, then `GITHUB_TOKEN` for GitHub.com.
2. `GH_ENTERPRISE_TOKEN`, then `GITHUB_ENTERPRISE_TOKEN` for Enterprise hosts.
3. The selected hosts configuration and Native credential backend.
4. `GH_HOST` selects the default hostname when no explicit host is supplied.

Tokens must not appear in argv, trace records, Debug output, ordinary logs, or
error messages. Explicit `auth token` and `auth status --show-token` output are
separate user-requested behaviors; fixtures must use synthetic credentials only.
Enterprise REST requests use `/api/v3` and GraphQL requests use
`/api/graphql`; GitHub.com uses its public REST and GraphQL origins.

## Oracle corpus policy

Each implemented command gets a deterministic help case, parse/error cases, a
fixture-server request case where network behavior matters, and an output case
for JSON/raw/template modes. Snapshots are review artifacts, not a replacement
for semantic assertions: tests must still assert exit status, stdout/stderr
separation, redaction, pagination, and request shape. No test or CI job may use
a real GitHub token or a real account.

The current checked-in corpus is upstream reference collection only. Network
fixture capture is marked skipped in its manifest, and it contains no completed
candidate differential, PTY, fake editor/browser, or full command acceptance.
`gh licenses` reports third-party software notices; repository license browsing
belongs to `gh repo license`. A fresh configuration includes the default
`co: pr checkout` alias, which is therefore part of local alias behavior.
