# CLI usage

The Native CLI provides non-interactive MoonHub commands for people and AI
agents. It uses the proposed [MoonHub API contracts](../README.md#api-contracts);
real-server integration remains pending. Browser pages and GitHub API endpoints
are not supported transports.

## Run the client

From a source checkout:

```sh
moon update
moon run cmd/main -- --help
moon build --target native --release --deny-warn
```

The build output is `_build/native/release/build/cmd/main/main.exe` on Native
hosts, including macOS and Linux. Delivery candidates stage it as `moonhub-gh`
(`moonhub-gh.exe` on Windows). Examples below use `gh` as shorthand for that
executable; `moon run cmd/main --` can replace it.

The HTTP, configuration-file and trace-file adapters are Native-only. Linux x64,
macOS arm64 and Windows x64 have hosted fixture verification. Wasm, Wasm GC and
JavaScript checks cover portable packages, not a runnable CLI on those targets.
See [build and release instructions](../development/release.md).

## Configure a host and credentials

| Setting | Precedence and behavior |
| --- | --- |
| Host | `--host` then `MOONHUB_HOST`; no default server |
| Repository | Explicit positional repository or `--repo`/`-R`, then `MOONHUB_REPO`; conflicting explicit references fail |
| Token | `MOONHUB_TOKEN`, then the file selected by `--config`; no token argv option |
| Trace file | Only the explicit `--trace PATH`; its private parent directory must exist |

A host is a complete origin such as `https://moonhub.example`. HTTPS is required
except for supported loopback HTTP origins. Tokens are bound to that origin,
including non-default ports. An invalid higher-priority token fails without
falling back to another account. The client does not discover local Git remotes,
find a default config file, issue tokens or implement interactive login.

An explicitly selected config file uses this format:

```json
{
  "version": 1,
  "hosts": {
    "https://moonhub.example": "replace-with-an-existing-token"
  }
}
```

Store it in a private directory and pass `--config /private/hosts.json`. Host
keys must be canonical origins. See the [SDK configuration rules](sdk.md#credentials-and-configuration)
for validation and size limits.

## Commands

| Command | Behavior |
| --- | --- |
| `meta` | API version, server version and advertised capabilities |
| `auth status` | Query the identity associated with the configured token |
| `repo list` / `repo view [OWNER/NAME]` | List visible repositories or inspect one |
| `issue list` / `issue view NUMBER` | Read issues |
| `issue create` / `issue comment NUMBER` | Create an issue or append a comment |
| `issue close NUMBER` / `issue reopen NUMBER` | Change issue state with `--if-match` |
| `pr list` / `pr view NUMBER` | Read MoonHub merge requests |
| `pr create` / `pr comment NUMBER` / `pr merge NUMBER` | Create, comment on or submit a merge request for merging |
| `pipeline list` / `pipeline view NUMBER` | Read pipeline run summaries |
| `pipeline cancel NUMBER` / `pipeline rerun NUMBER` | Request cancellation or create a new run from the original snapshot |
| `api /PATH` | Send one generic JSON API request |
| `trace list` / `trace show OPERATION_ID` | Query a local trace file without networking |

```sh
gh meta --host https://moonhub.example --json
gh auth status --host https://moonhub.example --config /private/hosts.json --json
gh repo view team/demo --host https://moonhub.example --json
gh issue list --host https://moonhub.example -R team/demo --paginate --json
gh issue create --host https://moonhub.example -R team/demo --title 'Example issue' --body-file issue.md --json
gh issue close 7 --host https://moonhub.example -R team/demo --if-match '"tag-from-view"' --json
gh pr create --host https://moonhub.example -R team/demo --title 'Example change' --source feature --target main --draft --json
gh pipeline view 42 --host https://moonhub.example -R team/demo --json
```

All domains, repositories and tags in these examples are placeholders. Conditional
writes require the actual strong ETag returned by `view --json`; the client does
not construct a tag, silently refresh it or bypass a stale precondition. Issue
comments do not require an ETag; MR comments do. Full write arguments and
requirements are in `--help` and the [mutation contract](../contracts/mutation-api.md).

Text bodies use either `--body TEXT` or `--body-file PATH`; `--body-file -` reads
UTF-8 stdin. The Native reader permits at most 80,000 bytes and 30 seconds; typed
descriptions/comments are limited to 20,000 UTF-16 code units. Required comment
bodies must contain non-whitespace text.

For generic requests, `/PATH` is relative to `/api/v1`:

```sh
gh api '/repos/team/demo/issues?page=2&per_page=30' --host https://moonhub.example --json
gh api /repos/team/demo/issues -X POST --input issue.json --host https://moonhub.example --json
```

The generic command returns the entire JSON value, applies no typed DTO schema
and never paginates or retries, including GET. Input must be valid UTF-8 JSON;
credentials and routing/framing headers are reserved. See the
[API command contract](../contracts/api-command.md) for header and result rules.

## Pagination and read retries

Lists default to page 1 and 30 items per page. `--page` accepts 1–1,000,000;
`--per-page` accepts 1–100. `--paginate` follows validated next links with a
default 20-page budget, configurable through `--max-pages` to 1–100, and a fixed
1,000-item limit. A remaining next page at either budget is an explicit failure.
Malformed or failed later pages do not produce a partial success array.

Typed GETs allow three attempts per page by default. `--max-attempts 1` disables
retries; the maximum is 5. Only transport failures and HTTP 429/502/503/504 are
eligible, subject to bounded waits and `Retry-After`. All writes, generic `api`
and raw SDK `execute` use one attempt. See [read retries](retries.md).

## Output and exit codes

`--json` is a boolean switch. Successful typed reads print one compact JSON
object to stdout, with optional DTO values represented as scalars or `null`:

```json
{"version":1,"data":[],"pagination":{"pages":1,"next":null},"etag":null}
```

Single-resource reads use `pagination: null`. Writes also report `outcome`.
Generic API and trace commands have their own documented result envelopes.
GitHub-style JSON field selection, `--jq` and templates are not supported.

Failures leave stdout empty and print a versioned error to stderr. Trace failures
add a separate warning without changing the request result. Consume JSON-mode
stderr as JSONL: an invocation can have both an error and a warning. Diagnostics
use fixed client messages and safe request IDs, not raw server error bodies.
Intentional successful JSON output may contain private resource content.

| Exit | Meaning |
| --- | --- |
| 0 | Success, including a separate trace warning |
| 1 | API, server, response-decoding or command failure |
| 2 | Invalid local input or configuration |
| 3 | Authentication or permission failure (401/403) |
| 4 | Conflict or stale precondition (409/412) |
| 5 | Transport failure |

HTTP 400/422 use exit 1; locally rejected arguments use exit 2. Malformed trace
records use exit 1, while unreadable trace input uses exit 2. Output failures or
process interruption can prevent a complete JSON result and are not proof that
a remote write was rolled back.

For writes, `applied` confirms the validated synchronous result; `accepted`
confirms submission for later work. Inspect `pr view` or `pipeline view` for
eventual completion. An `unknown` outcome means the request may have committed:
inspect server state before deciding to send another write. A trace warning is
never a reason to resubmit. See [tracing](tracing.md) for offline correlation.
