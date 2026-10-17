# Repository context status

The repository context boundary is implemented in `github_cli/repository.mbt`.
It accepts `OWNER/REPO`, `HOST/OWNER/REPO`, and HTTP(S), `ssh://`, `git://`,
and scp-style remotes. It strips a terminal `.git`, keeps Enterprise ports in
the host identity, rejects credentials in HTTP URLs, rejects local paths and
query/fragment data, and substitutes `{owner}`, `{repo}`, and `{branch}`.

`native/github_repository.mbt` resolves an explicit repository, `GH_REPO`, or
the local Git remotes using argument-array process calls. The default remote
priority is `upstream`, `github`, `origin`, then other names. With
`respect_resolved=true`, `remote.<name>.gh-resolved=base` selects that remote;
an explicit configured repository selects the configured identity. API callers
can use `respect_resolved=false` for the basic remote policy. `GH_REPO` and
`{branch}` are mutually exclusive in this implementation. A
branch-only helper is available as `resolve_current_branch` when no repository
identity is needed.

The process adapter sets `GIT_TERMINAL_PROMPT=0`, `GIT_OPTIONAL_LOCKS=0`, and
`LC_ALL=C`; captures stdout without a shell; caps each stream at 1 MiB; and
uses a 10-second deadline. Cancellation is propagated. Tests cover fake-git
injection, HTTPS/SSH/scp parsing, a temporary real Git repository, configured
remote selection, branch resolution, and process cancellation.

The native command layer also handles `gh repo clone` and `gh pr checkout`
through the argv-only Git adapter. Clone validates the repository identity,
branch/depth values, and target directory before invoking `git clone`; pull
request checkout fetches `pull/<number>/head` into a validated local branch and
then invokes `git checkout`. Neither workflow embeds credentials in a remote
URL or shell command.

Validation completed:

```text
moon check --target native native
moon test --target native native --filter 'repository*' --warn-list -a
moon test --target native github_cli --filter 'repository*'
moon test --target wasm github_cli --filter 'repository*' --warn-list -a
moon test --target wasm-gc github_cli --filter 'repository*' --warn-list -a
moon test --target js github_cli --filter 'repository*' --warn-list -a
```

The focused Native repository suite is 8/8. The pure repository suite is 4/4
on each Native, Wasm, Wasm GC, and JavaScript target. Package API regeneration
was performed before the branch-only helper was added; the final integrated
`moon info` will regenerate the complete shared interface.

This is bounded repository support, not a full parity claim. SSH config
host aliases, known-GitHub-host filtering, percent-decoding remote segments,
IPv6 hosts, remote push-URL policies, interactive remote selection and exact
stderr snapshots are not covered yet.

Pinned upstream source inspection was unavailable in this environment, so
the remote precedence and placeholder behavior above are tracked as the
project's compatibility policy and should be checked against the v2.102.0
oracle before release.
