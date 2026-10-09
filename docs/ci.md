# Hosted Native verification

[Native CI](https://github.com/moonbit-community/gh/actions/workflows/ci.yml)
runs on every push, pull request and manual dispatch. Each matrix job executes
on its own host; all-target checking is an additional type check, not the source
of the cross-platform runtime claim.

| Runner | Native target |
| --- | --- |
| `ubuntu-24.04` | Linux x64 |
| `macos-15` | macOS arm64 |
| `windows-2025` | Windows x64 |

The workflow pins the MoonBit toolchain and core to `0.10.14+7d59c7ec9`, and pins
the checkout, setup and artifact actions to commits. Actual tool versions and
host details are also recorded in each candidate manifest.

## What must pass

1. Source and `.mbtx` formatting; regeneration of committed public interfaces.
2. Native and all-target MoonBit checks with `--deny-warn`, Native tests, and a
   release build.
3. The staged executable's version/help and all 66 CLI fixture scenarios.
4. Candidate verification and release-tool regressions, including running the
   bundled verifier after relocating a candidate copy.

These commands reuse the local `.mbtx` runners. No OS matrix entry uses
`continue-on-error`, and matrix failure does not cancel the other platforms.
Runtime and fixture failures fail the job; tests are not removed to obtain a
green badge.

## Evidence and failures

Each job uploads `native-<platform>-<commit>` for 14 days, including the candidate
directory and the release regression report when generated. Upload is attempted
even after failure so a started runner's status and diagnostic logs survive.
An upload or a directory alone is not success: require the job to be green,
`ci-candidate/manifest.json` to exist, and `increment-6-smoke.json` to identify
that same manifest and binary. Missing files remain a failed or incomplete run.

Artifacts are CI evidence, not signed releases. GitHub's artifact ZIP does not
retain POSIX execute permissions; restore the executable bit before directly
running a downloaded Linux/macOS binary. Verify the unchanged bytes with the
bundled verifier as described in [release.md](release.md). Keep its build cache
outside the candidate directory.

## Platform boundaries

Wire JSON has a depth budget of 128 on every platform. The original 1024-depth
test exhausted the default Windows Native stack; both arrays and objects now
exercise boundary acceptance, round-trip output, and rejection at depths 129,
1024 and 10000. The client continues to reuse the upstream parser.

Windows MSVC emits C4005 for `EINVAL` in the pinned upstream async library's
`src/internal/event_loop/fs.c`. This is a dependency C compiler diagnostic,
retained in the evidence logs; `--deny-warn` gates MoonBit diagnostics and does
not mean that every upstream C compilation is warning-free.

POSIX trace files are created with mode 0600 and existing files tightened.
Windows uses the ACL inherited from the explicitly selected parent directory;
the caller must select a private directory. The pinned upstream filesystem API
cannot inspect or change Windows ACLs and does not implement `chmod` there.
Neither a no-op POSIX permission adapter nor a successful trace append proves
that an arbitrary Windows directory is private.

The matrix verifies Native client behavior with loopback HTTP and temporary
files. Real MoonHub acceptance, system HTTPS trust and invalid certificate
rejection, a full ACL/permission review, signing, and registry publication remain
the independent gates documented in [release.md](release.md). A fixture cannot
prove the remote outcome of an interrupted write.

## Execution record

The first hosted run is pending. Record results only after GitHub has completed
the jobs and uploaded the associated evidence; a workflow definition alone does
not establish platform support.
