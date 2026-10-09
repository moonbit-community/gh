///|
test "upstream argument parser handles globals, env precedence and command plans" {
  guard @cli.parse(
      [
        "--host", "https://moonhub.example", "issue", "list", "-Rteam/demo", "--json",
        "--per-page=50", "--paginate",
      ],
      host_env="https://ignored.example",
      repo_env="ignored/repo",
    )
    is Ok(@cli.Run(opts)) else {
    fail("valid arguments rejected")
  }
  assert_eq(opts.base_url, "https://moonhub.example")
  assert_true(
    opts.command is @cli.Issues(repo) &&
    repo.owner == "team" &&
    repo.name == "demo",
  )
  assert_true(opts.json && opts.paginate)
  assert_eq(opts.page, 1)
  assert_eq(opts.per_page, 50)
  assert_eq(opts.max_pages, 20)
  guard @cli.parse(
      ["pr", "view", "42"],
      host_env="http://localhost:8080/",
      repo_env="team/demo",
    )
    is Ok(@cli.Run(opts)) else {
    fail("environment fallback rejected")
  }
  assert_eq(opts.base_url, "http://localhost:8080")
  assert_true(opts.command is @cli.MergeRequest(_, 42))
  guard @cli.parse(
      ["repo", "view", "team/explicit"],
      host_env="https://moonhub.example",
      repo_env="team/env",
    )
    is Ok(@cli.Run(opts)) else {
    fail("positional repository rejected")
  }
  assert_true(opts.command is @cli.Repository(repo) && repo.name == "explicit")
}

///|
test "help and version are return values without host or process exits" {
  for
    args in [
      [],
      ["--help"],
      ["-h"],
      ["issue", "--help"],
      ["pr", "view", "--help"],
      ["repo"],
    ] {
    assert_true(
      @cli.parse(args) is Ok(@cli.Help(text)) && text.contains("MoonHub"),
    )
  }
  assert_true(@cli.parse(["--version"]) is Ok(@cli.Version))
}

///|
test "invalid arguments are bounded, unambiguous and never echo values" {
  for
    args in [
      ["issue", "list"],
      ["issue", "view", "0", "-R", "team/demo"],
      ["issue", "view", "2147483648", "-R", "team/demo"],
      ["issue", "list", "-R", "../demo"],
      ["repo", "view", "team/a", "--repo", "team/b"],
      ["repo", "list", "--page", "0"],
      ["repo", "list", "--per-page", "101"],
      ["repo", "list", "--max-pages", "101"],
      ["repo", "view", "--paginate"],
      ["meta", "--token", "secret-argv-token"],
      ["meta", "--host", "https://secret-argv-token@moonhub.example"],
      ["meta", "--config", ""],
      ["issue", "create"],
    ] {
    guard @cli.parse(args, host_env="https://moonhub.example") is Err(message) else {
      fail("invalid arguments accepted")
    }
    assert_false(message.contains("secret-argv-token"))
  }
  assert_true(@cli.parse(["meta"]) is Err(_))
}
