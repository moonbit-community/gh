///|
test "hosts yaml selects only the requested host" {
  let source =
    #|github.com:
    #|  user: alice
    #|  oauth_token: github-secret
    #|  git_protocol: ssh
    #|ghe.example.com:
    #|  user: bob
    #|  oauth_token: "enterprise-secret"
  assert_eq(
    @github_auth.hosts_token(source, host="ghe.example.com"),
    Ok(Some("enterprise-secret")),
  )
  assert_eq(
    @github_auth.hosts_token(source, host="github.com"),
    Ok(Some("github-secret")),
  )
  assert_eq(
    @github_auth.hosts_token(source, host="missing.example.com"),
    Ok(None),
  )
}

///|
test "hosts yaml rejects aliases tabs malformed and invalid selected tokens" {
  assert_true(
    @github_auth.hosts_token(
      "github.com:\n\t oauth_token: secret",
      host="github.com",
    )
    is Err(@github_auth.InvalidConfig),
  )
  assert_true(
    @github_auth.hosts_token(
      "github.com:\n  oauth_token: bad secret",
      host="github.com",
    )
    is Err(@github_auth.InvalidToken),
  )
  assert_true(
    @github_auth.hosts_token(
      "github.com:\n  oauth_token: &token",
      host="github.com",
    )
    is Err(@github_auth.InvalidConfig),
  )
}

///|
test "environment credentials win over hosts yaml" {
  let source = "github.com:\n  oauth_token: stored-secret"
  let environment = @github_auth.Environment::new(gh_token="environment-secret")
  let config = match @github_auth.resolve_with_hosts(environment, source) {
    Ok(value) => value
    Err(_) => abort("expected resolved config")
  }
  assert_eq(config.token(), Some("environment-secret"))
}

///|
test "hosts yaml uses the active account without leaking other accounts" {
  let source =
    #|github.com:
    #|  user: active
    #|  users:
    #|    inactive:
    #|      oauth_token: inactive-fixture-token
    #|    active:
    #|      oauth_token: active-fixture-token
  assert_eq(
    @github_auth.hosts_token(source, host="github.com"),
    Ok(Some("active-fixture-token")),
  )
  assert_eq(@github_auth.hosts_token(source, host="ghe.example"), Ok(None))
}

///|
test "hosts yaml rejects duplicate keys and unsupported structures" {
  for
    source in [
      "github.com:\n  oauth_token: first\n  oauth_token: second", "github.com:\n  users: [one, two]",
      "github.com:\n  oauth_token: *shared", "github.com: {oauth_token: fixture}",
    ] {
    assert_true(@github_auth.hosts_token(source, host="github.com") is Err(_))
  }
  assert_eq(@github_auth.hosts_token("", host="github.com"), Ok(None))
  assert_eq(
    @github_auth.hosts_token("# empty fixture\n", host="github.com"),
    Ok(None),
  )
}
