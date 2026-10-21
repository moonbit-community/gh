///|
test "github.com token precedence and URL defaults" {
  let env = @github_auth.Environment::new(
    gh_token="gh-secret",
    github_token="github-secret",
  )
  let config = expect_config(
    @github_auth.resolve(env, stored_token="stored-secret"),
  )
  assert_eq(config.host(), "github.com")
  assert_eq(config.rest_base_url(), "https://api.github.com")
  assert_eq(config.graphql_url(), "https://api.github.com/graphql")
  assert_eq(config.token(), Some("gh-secret"))
  assert_true(config.token_source() is @github_auth.GhToken)
}

///|
test "fixed gh local instance endpoints and token precedence remain scoped to exact hostname" {
  let config = expect_config(
    @github_auth.resolve(
      @github_auth.Environment::new(
        gh_host="GITHUB.LOCALHOST",
        gh_token="local-only",
        gh_enterprise_token="wrong-scope",
      ),
    ),
  )
  assert_eq(config.rest_base_url(), "http://api.github.localhost")
  assert_eq(config.graphql_url(), "http://api.github.localhost/graphql")
  assert_eq(config.token(), Some("local-only"))
  let other = expect_config(
    @github_auth.resolve(
      @github_auth.Environment::new(
        gh_host="github.localhost.invalid",
        gh_token="must-not-leak",
      ),
    ),
  )
  assert_eq(other.token(), None)
  assert_eq(other.rest_base_url(), "https://github.localhost.invalid/api/v3")
}

///|
test "github.com falls through to GITHUB_TOKEN and stored token" {
  let from_github = expect_config(
    @github_auth.resolve(
      @github_auth.Environment::new(github_token="github-secret"),
    ),
  )
  assert_eq(from_github.token(), Some("github-secret"))
  assert_true(from_github.token_source() is @github_auth.GithubToken)
  let from_store = expect_config(
    @github_auth.resolve(
      @github_auth.Environment::new(gh_token="", github_token=""),
      stored_token="stored-secret",
    ),
  )
  assert_eq(from_store.token(), Some("stored-secret"))
  assert_true(from_store.token_source() is @github_auth.Stored)
}

///|
test "enterprise token precedence and endpoint paths" {
  let env = @github_auth.Environment::new(
    gh_host="ghe.example.test:8443",
    gh_enterprise_token="enterprise-secret",
    github_enterprise_token="github-enterprise-secret",
    gh_token="github-secret",
  )
  let config = expect_config(@github_auth.resolve(env))
  assert_eq(config.host(), "ghe.example.test:8443")
  assert_eq(config.rest_base_url(), "https://ghe.example.test:8443/api/v3")
  assert_eq(config.graphql_url(), "https://ghe.example.test:8443/api/graphql")
  assert_eq(config.token(), Some("enterprise-secret"))
  assert_true(config.token_source() is @github_auth.GhEnterpriseToken)
}

///|
test "enterprise does not use github.com token variables" {
  let env = @github_auth.Environment::new(
    gh_host="ghe.example.test",
    gh_token="github-secret",
    github_token="github-secret",
  )
  let config = expect_config(@github_auth.resolve(env))
  assert_eq(config.token(), None)
  assert_true(config.token_source() is @github_auth.Unspecified)
}

///|
test "host validation rejects URL injection and normalizes case" {
  let normalized = expect_config(
    @github_auth.resolve(
      @github_auth.Environment::new(gh_host="GHE.Example.TEST"),
    ),
  )
  assert_eq(normalized.host(), "ghe.example.test")
  for
    host in [
      "https://ghe.example.test", "ghe.example.test/api/v3", "ghe.example.test?x",
      "ghe.example.test#x", "ghe example.test",
    ] {
    assert_true(
      @github_auth.resolve(@github_auth.Environment::new(gh_host=host))
      is Err(@github_auth.InvalidHost),
    )
  }
}

///|
test "invalid selected token does not fall back" {
  assert_true(
    @github_auth.resolve(
      @github_auth.Environment::new(gh_token="bad secret", github_token="good"),
    )
    is Err(@github_auth.InvalidToken),
  )
  assert_true(
    @github_auth.resolve(
      @github_auth.Environment::new(
        gh_host="ghe.example",
        gh_enterprise_token="bad\n",
      ),
      stored_token="good",
    )
    is Err(@github_auth.InvalidToken),
  )
}

///|
fn expect_config(
  result : Result[@github_auth.Config, @github_auth.AuthError],
) -> @github_auth.Config {
  match result {
    Ok(value) => value
    Err(_) => abort("expected valid GitHub auth config")
  }
}
