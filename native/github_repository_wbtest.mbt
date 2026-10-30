///|
async test "repository explicit and GH_REPO overrides do not launch git" {
  let mut calls = 0
  let run : async (Array[String]) -> RepositoryGitResult = _ => {
    calls += 1
    { code: 99, stdout: "", }
  }
  guard resolve_repository_with(
      repo="acme/explicit",
      gh_repo="other/env",
      gh_host="ghe.example",
      run~,
    )
    is Ok(repo) else {
    fail("explicit repository failed")
  }
  assert_eq(repo.full_name(), "acme/explicit")
  assert_eq(repo.host(), "ghe.example")
  guard resolve_repository_with(gh_repo="example.test/acme/env", run~)
    is Ok(repo) else {
    fail("environment repository failed")
  }
  assert_eq(repo.host(), "example.test")
  assert_eq(calls, 0)
  assert_true(resolve_repository_with(repo="bad", run~) is Err(_))
  assert_true(
    resolve_repository_with(gh_repo="acme/env", need_branch=true, run~)
    is Err(_),
  )
  assert_eq(calls, 0)
}

///|
async test "repository remotes prefer upstream github origin and configured base" {
  let output = "origin\thttps://github.com/acme/origin.git (fetch)\ngithub\tgit@github.com:acme/github.git (fetch)\nupstream\tssh://git@enterprise.example/acme/upstream.git (fetch)\norigin\thttps://github.com/acme/push.git (push)\n"
  let calls : Array[Array[String]] = []
  let run : async (Array[String]) -> RepositoryGitResult = args => {
    calls.push(args.copy())
    if args[0] == "remote" {
      { code: 0, stdout: output, }
    } else {
      { code: 1, stdout: "", }
    }
  }
  guard resolve_repository_with(run~) is Ok(repo) else {
    fail("remote resolution failed")
  }
  assert_eq(repo.full_name(), "acme/upstream")
  assert_eq(repo.host(), "enterprise.example")
  assert_eq(calls[0], ["remote", "-v"])
  assert_eq(calls[1], [
    "config", "--null", "--get-regexp", "^remote\\..*\\.gh-resolved$",
  ])
  let configured : async (Array[String]) -> RepositoryGitResult = args => {
    if args[0] == "remote" {
      { code: 0, stdout: output, }
    } else {
      { code: 0, stdout: "remote.origin.gh-resolved\nbase\u0000", }
    }
  }
  guard resolve_repository_with(run=configured) is Ok(repo) else {
    fail("configured base failed")
  }
  assert_eq(repo.full_name(), "acme/origin")
  guard resolve_repository_with(run=configured, respect_resolved=false)
    is Ok(repo) else {
    fail("basic policy failed")
  }
  assert_eq(repo.full_name(), "acme/upstream")
}

///|
async test "repository configured override inherits remote host and branch uses array arguments" {
  let calls : Array[Array[String]] = []
  let run : async (Array[String]) -> RepositoryGitResult = args => {
    calls.push(args.copy())
    match args[0] {
      "remote" =>
        {
          code: 0,
          stdout: "origin\tgit@enterprise.example:fork/repo.git (fetch)\n",
        }
      "config" =>
        { code: 0, stdout: "remote.origin.gh-resolved\nbase/repo\u0000", }
      _ => { code: 0, stdout: "feature/topic\n", }
    }
  }
  guard resolve_repository_with(run~, need_branch=true) is Ok(repo) else {
    fail("repository and branch failed")
  }
  assert_eq(repo.host(), "enterprise.example")
  assert_eq(repo.full_name(), "base/repo")
  assert_eq(repo.branch(), Some("feature/topic"))
  assert_eq(calls[2], ["symbolic-ref", "--quiet", "--short", "HEAD"])
}

///|
async test "repository no remote detached branch and git failure are ordinary errors" {
  for
    (code, stdout) in [(0, ""), (128, ""), (0, "origin\t/tmp/local (fetch)\n")] {
    let result = resolve_repository_with(run=_ => { code, stdout, })
    guard result is Err(output) else { fail("expected resolution failure") }
    assert_eq(output.exit_code(), 1)
    assert_eq(output.stdout(), "")
  }
  guard resolve_repository_with(repo="acme/repo", need_branch=true, run=_ => {
      code: 1,
      stdout: "",
    })
    is Err(output) else {
    fail("expected detached branch failure")
  }
  assert_true(output.stderr().contains("not on any branch"))
}

///|
async test "repository git subprocess captures output without a shell" {
  let result = repository_git(["--version"])
  assert_eq(result.code, 0)
  assert_true(result.stdout.has_prefix("git version "))
}

///|
async test "repository real git fixture resolves NUL configuration and branch" {
  let directory = @fs.tmpdir(prefix="gh-repository-")
  defer @fs.rmdir(directory, recursive=true)
  assert_eq(repository_git(["init", "--quiet", directory]).code, 0)
  for
    args in [
      ["remote", "add", "origin", "git@github.com:fork/widgets.git"],
      ["remote", "add", "upstream", "https://github.com/acme/widgets.git"],
      ["config", "remote.origin.gh-resolved", "base"],
      ["symbolic-ref", "HEAD", "refs/heads/feature/topic"],
    ] {
    let invocation = ["-C", directory]
    for arg in args {
      invocation.push(arg)
    }
    assert_eq(repository_git(invocation).code, 0)
  }
  let trace : Array[String] = []
  let run : async (Array[String]) -> RepositoryGitResult = args => {
    let invocation = ["-C", directory]
    for arg in args {
      invocation.push(arg)
    }
    trace.push("git \{args.join(" ")}")
    errdefer trace.push("git raised before producing a result")
    let result = repository_git(invocation)
    trace.push("exit \{result.code}; stdout: \{result.stdout}")
    result
  }
  let resolved = resolve_repository_with(need_branch=true, run~)
  guard resolved is Ok(repo) else {
    let reason = match resolved {
      Err(output) => output.stderr()
      _ => "unexpected resolution result"
    }
    fail("real git resolution failed: \{reason}\n\{trace.join("\n")}")
  }
  assert_eq(repo.full_name(), "fork/widgets")
  assert_eq(repo.branch(), Some("feature/topic"))
  let prioritized = resolve_repository_with(respect_resolved=false, run~)
  guard prioritized is Ok(repo) else {
    let reason = match prioritized {
      Err(output) => output.stderr()
      _ => "unexpected priority result"
    }
    fail("real git priority failed: \{reason}\n\{trace.join("\n")}")
  }
  assert_eq(repo.full_name(), "acme/widgets")
}

///|
async test "repository cancellation is not converted to an ordinary git error" {
  @async.with_task_group() <| group => {
    let mut started = false
    let task = group.spawn(() => {
      resolve_repository_with(run=_ => {
        started = true
        @async.sleep(30000)
        { code: 0, stdout: "", }
      })
    })
    while !started {
      @async.pause()
    }
    task.cancel()
    let cancelled = try {
      ignore(task.wait())
      false
    } catch {
      @async.WaitedTaskAlreadyCancelled => true
      _ => false
    }
    assert_true(cancelled)
  }
}

///|
async test "repository branch-only lookup does not require a remote" {
  let calls : Array[Array[String]] = []
  let run : async (Array[String]) -> RepositoryGitResult = args => {
    calls.push(args)
    { code: 0, stdout: "feature/local\n", }
  }
  guard repository_current_branch(run~) is Ok(branch) else {
    fail("branch failed")
  }
  assert_eq(branch, "feature/local")
  assert_eq(calls, [["symbolic-ref", "--quiet", "--short", "HEAD"]])
  assert_true(
    repository_current_branch(gh_repo="acme/override", run~) is Err(_),
  )
  assert_eq(calls.length(), 1)
}
