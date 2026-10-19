///|
async fn pr_merge_fixture(
  flags : Array[String],
) -> (@github_cli.Output, Array[Bytes?]) {
  let bodies : Array[Bytes?] = []
  let client = match
    @github.Client::new(
      config=@github.ClientConfig::new(base_url="https://api.github.example"),
      transport=@github.Transport::new(send=request => {
        assert_eq(request.verb(), "PUT")
        assert_eq(request.path(), "/repos/acme/widgets/pulls/42/merge")
        bodies.push(request.body())
        Ok(@github.RawResponse::new(status=200, body=b"{\"merged\":true}"))
      }),
    ) {
    Ok(value) => value
    Err(_) => fail("fixture client setup failed")
  }
  // Put flags before the PR number to ensure boolean short options do not
  // consume the positional argument as their value.
  let args = ["pr", "merge"]
  args.append(flags)
  args.append(["42", "-R", "acme/widgets"])
  let options = match @github_cli.parse(args) {
    @github_cli.Business(value) => value
    _ => fail("expected pull request business invocation")
  }
  let output = @native.execute_github_business(
    options,
    client~,
    base_url="https://api.github.example",
  )
  (output, bodies)
}

///|
fn pr_merge_fixture_body(bodies : Array[Bytes?]) -> Map[String, Json] raise {
  assert_eq(bodies.length(), 1)
  guard bodies[0] is Some(bytes) else { fail("merge body missing") }
  let body = @json.parse(@utf8.decode(bytes)) catch {
    _ => fail("merge body is not JSON")
  }
  guard body is Object(fields) else { fail("merge body is not an object") }
  fields
}

///|
async test "pr merge maps standard long and short strategy flags" {
  for
    (flag, strategy) in [
      ("--merge", "merge"),
      ("--squash", "squash"),
      ("--rebase", "rebase"),
      ("-m", "merge"),
      ("-s", "squash"),
      ("-r", "rebase"),
      ("--squash=true", "squash"),
    ] {
    let (output, bodies) = pr_merge_fixture([flag])
    assert_eq(output.exit_code(), 0)
    let body = pr_merge_fixture_body(bodies)
    assert_eq(body.get("merge_method"), Some(Json::string(strategy)))
    assert_eq(body.length(), 1)
  }
}

///|
async test "pr merge preserves expected head commit as a string" {
  for
    flags in [
      ["--merge", "--match-head-commit", "000123"],
      ["--merge", "--match-head-commit=000123"],
      ["--merge", "--sha", "000123"],
      ["--merge", "--match-head-commit", "000123", "--sha", "000123"],
    ] {
    let (output, bodies) = pr_merge_fixture(flags)
    assert_eq(output.exit_code(), 0)
    let body = pr_merge_fixture_body(bodies)
    assert_eq(body.get("sha"), Some(Json::string("000123")))
    assert_eq(body.get("merge_method"), Some(Json::string("merge")))
    assert_eq(body.length(), 2)
  }
}

///|
async test "pr merge retains nonconflicting REST aliases and false strategies" {
  for
    flags in [
      ["--merge-method", "squash"],
      ["--squash", "--merge-method", "squash"],
      ["--merge=false", "--rebase=false", "--squash"],
    ] {
    let (output, bodies) = pr_merge_fixture(flags)
    assert_eq(output.exit_code(), 0)
    let body = pr_merge_fixture_body(bodies)
    assert_eq(body.get("merge_method"), Some(Json::string("squash")))
    assert_eq(body.length(), 1)
  }
  let (output, bodies) = pr_merge_fixture([
    "--merge-method", "merge", "--commit-title", "123", "--commit-message", "false",
  ])
  assert_eq(output.exit_code(), 0)
  let body = pr_merge_fixture_body(bodies)
  assert_eq(body.get("commit_title"), Some(Json::string("123")))
  assert_eq(body.get("commit_message"), Some(Json::string("false")))
}

///|
async test "pr merge rejects conflicting strategy and expected head before network" {
  for
    flags in [
      ["--merge", "--squash"],
      ["--merge", "--rebase"],
      ["--squash", "--rebase"],
      ["-m", "-r"],
      ["--merge=true", "--squash=true"],
      ["--merge", "--merge-method", "rebase"],
      ["--match-head-commit", "abc123", "--sha", "def456"],
      ["--merge-method", "unknown"],
      ["--merge=unknown"],
      ["--match-head-commit="],
      ["--sha="],
      ["--merge-method="],
      ["--match-head-commit", "--merge"],
      ["--sha", "--merge"],
      ["--merge-method", "--merge"],
    ] {
    let (output, bodies) = pr_merge_fixture(flags)
    assert_true(output.exit_code() != 0)
    assert_eq(bodies.length(), 0)
  }
}

///|
async test "pr merge preserves unspecified strategy request body" {
  let (output, bodies) = pr_merge_fixture([])
  assert_eq(output.exit_code(), 0)
  assert_eq(bodies, [None])
}
