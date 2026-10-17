///|
test "repository identity supports explicit names and enterprise hosts" {
  for
    (input, host, name) in [
      ("Acme/Widgets", "github.com", "Acme/Widgets"),
      ("GHE.EXAMPLE:8443/Acme/Widgets.git", "ghe.example:8443", "Acme/Widgets"),
      ("https://github.com/Acme/Widgets/", "github.com", "Acme/Widgets"),
    ] {
    guard @github_cli.RepositoryContext::parse(input) is Ok(repo) else {
      fail("invalid repository")
    }
    assert_eq(repo.host(), host)
    assert_eq(repo.full_name(), name)
    assert_eq(repo.branch(), None)
  }
  guard @github_cli.RepositoryContext::parse(
      "acme/repo",
      default_host="ghe.example",
    )
    is Ok(repo) else {
    fail("invalid repository")
  }
  assert_eq(repo.host(), "ghe.example")
}

///|
test "repository remotes support HTTPS SSH and scp forms" {
  for
    input in [
      "https://github.com/Acme/Widgets.git", "git@github.com:Acme/Widgets.git", "ssh://git@github.com/Acme/Widgets.git",
      "ssh://git@github.com:2222/Acme/Widgets.git", "git://github.com/Acme/Widgets.git",
    ] {
    guard @github_cli.RepositoryContext::from_remote(input) is Ok(repo) else {
      fail("invalid remote")
    }
    assert_eq(repo.host(), "github.com")
    assert_eq(repo.owner(), "Acme")
    assert_eq(repo.name(), "Widgets")
  }
  guard @github_cli.RepositoryContext::from_remote(
      "https://GHE.EXAMPLE:8443/o/r",
    )
    is Ok(repo) else {
    fail("invalid remote")
  }
  assert_eq(repo.host(), "ghe.example:8443")
}

///|
test "repository malformed names and unsafe remotes are rejected" {
  for
    input in [
      "", "owner", "/owner/repo", "owner/", "owner/../repo", "owner/repo/extra/path",
      "bad host/owner/repo", "host:0/owner/repo", "host:65536/owner/repo", "owner/repo?token=secret",
    ] {
    assert_true(@github_cli.RepositoryContext::parse(input) is Err(_))
  }
  for
    input in [
      "/home/person/repo", "file:///tmp/repo", "https://user:secret@github.com/o/r",
      "git@github.com:o/r/extra", "https://github.com/o/r?token=secret", "https://github.com/o/r#fragment",
      "https://github.com/o/%72", "ssh://git@host:bad/o/r", "git@github.com:/o/r",
      "https://github.com/o/r\n",
    ] {
    assert_true(@github_cli.RepositoryContext::from_remote(input) is Err(_))
  }
}

///|
test "repository placeholders preserve raw branch and unknown placeholders" {
  guard @github_cli.RepositoryContext::parse("acme/widgets") is Ok(repo) else {
    fail("invalid repository")
  }
  assert_eq(
    repo.substitute("repos/{owner}/{repo}/{other}"),
    Ok("repos/acme/widgets/{other}"),
  )
  assert_true(repo.substitute("{branch}") is Err(@github_cli.MissingBranch))
  guard repo.with_branch("feature/topic") is Ok(branched) else {
    fail("invalid branch")
  }
  assert_eq(
    branched.substitute("repos/{owner}/{repo}/branches/{branch}/{repo}"),
    Ok("repos/acme/widgets/branches/feature/topic/widgets"),
  )
  assert_true(repo.with_branch("") is Err(@github_cli.MissingBranch))
}
