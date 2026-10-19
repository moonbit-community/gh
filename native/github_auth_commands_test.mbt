///|
async test "auth without credentials matches local oracle diagnostics" {
  let directory = @fs.tmpdir(prefix="gh-auth-fixture-")
  defer @fs.rmdir(directory, recursive=true)
  let environment = @github_auth.Environment::new()
  let token = @native.github_auth_command(
    ["token"],
    environment~,
    config_dir=directory,
  )
  assert_eq(token.exit_code(), 1)
  assert_eq(token.stderr(), "no oauth token found for github.com\n")
  let status = @native.github_auth_command(
    ["status"],
    environment~,
    config_dir=directory,
  )
  assert_eq(status.exit_code(), 1)
  assert_eq(status.stdout(), "")
  assert_eq(
    status.stderr(),
    "You are not logged into any GitHub hosts. To log in, run: gh auth login\n",
  )
  let json = @native.github_auth_command(
    ["status", "--json", "hosts"],
    environment~,
    config_dir=directory,
  )
  assert_eq(json.exit_code(), 0)
  assert_eq(json.stdout(), "{\"hosts\":{}}\n")
}

///|
async test "auth status verifies account and masks fixture token" {
  let directory = @fs.tmpdir(prefix="gh-auth-fixture-")
  defer @fs.rmdir(directory, recursive=true)
  let environment = @github_auth.Environment::new(
    gh_token="fixture-private-token",
  )
  let calls = Ref(0)
  let transport = @github.Transport::new(send=request => {
    calls.val += 1
    assert_eq(request.verb(), "GET")
    assert_eq(request.url(), "https://api.github.com/user")
    assert_true(
      request
      .headers()
      .contains(("Authorization", "Bearer fixture-private-token")),
    )
    Ok(
      @github.RawResponse::new(
        status=200,
        headers=[("X-OAuth-Scopes", "repo, read:org")],
        body=@utf8.encode("{\"login\":\"fixture-user\"}"),
      ),
    )
  })
  let result = @native.github_auth_command(
    ["status"],
    environment~,
    config_dir=directory,
    transport~,
  )
  assert_eq(calls.val, 1)
  assert_eq(result.exit_code(), 0)
  assert_true(result.stderr().contains("account fixture-user"))
  assert_false(result.stderr().contains("fixture-private-token"))
  assert_eq(result.stdout(), "")
}

///|
async test "auth status rejects invalid tokens and malformed successful responses" {
  let directory = @fs.tmpdir(prefix="gh-auth-fixture-")
  defer @fs.rmdir(directory, recursive=true)
  let environment = @github_auth.Environment::new(
    gh_token="fixture-private-token",
  )
  for
    (status, body) in [
      (401, "fixture-private-token"),
      (200, "{}"),
      (200, "not json"),
    ] {
    let transport = @github.Transport::new(send=_ => {
      Ok(@github.RawResponse::new(status~, body=@utf8.encode(body)))
    })
    let output = @native.github_auth_command(
      ["status"],
      environment~,
      config_dir=directory,
      transport~,
    )
    assert_eq(output.exit_code(), 1)
    assert_false(output.stderr().contains("fixture-private-token"))
    assert_false(output.stderr().contains("Logged in"))
    let json = @native.github_auth_command(
      ["status", "--json", "hosts"],
      environment~,
      config_dir=directory,
      transport~,
    )
    assert_eq(json.exit_code(), 0)
    assert_false(json.stdout().contains("fixture-private-token"))
    assert_true(json.stdout().contains("\"state\":\"error\""))
  }
}

///|
async test "auth token exports only explicitly requested fixture credential" {
  let directory = @fs.tmpdir(prefix="gh-auth-fixture-")
  defer @fs.rmdir(directory, recursive=true)
  @fs.write_file(
    directory + "/hosts.yml",
    "github.com:\n  user: active\n  oauth_token: active-fixture-token\n  users:\n    inactive:\n      oauth_token: inactive-fixture-token\n",
  )
  let environment = @github_auth.Environment::new(gh_token="env-fixture-token")
  let active = @native.github_auth_command(
    ["token"],
    environment~,
    config_dir=directory,
  )
  assert_eq(active.stdout(), "env-fixture-token\n")
  assert_eq(active.stderr(), "")
  let other = @native.github_auth_command(
    ["token", "--user", "inactive"],
    environment~,
    config_dir=directory,
  )
  assert_eq(other.stdout(), "inactive-fixture-token\n")
  assert_eq(other.stderr(), "")
  let missing = @native.github_auth_command(
    ["token", "--user", "missing"],
    environment~,
    config_dir=directory,
  )
  assert_eq(
    missing.stderr(),
    "no oauth token found for github.com account missing\n",
  )
}

///|
async test "auth hostname override uses enterprise URL and credential" {
  let directory = @fs.tmpdir(prefix="gh-auth-fixture-")
  defer @fs.rmdir(directory, recursive=true)
  let environment = @github_auth.Environment::new(
    gh_token="github-fixture-token",
    gh_enterprise_token="enterprise-fixture-token",
  )
  let transport = @github.Transport::new(send=request => {
    assert_eq(request.url(), "https://ghe.example/api/v3/user")
    assert_true(
      request
      .headers()
      .contains(("Authorization", "Bearer enterprise-fixture-token")),
    )
    Ok(
      @github.RawResponse::new(
        status=200,
        body=@utf8.encode("{\"login\":\"fixture-enterprise\"}"),
      ),
    )
  })
  let output = @native.github_auth_command(
    ["status", "--hostname", "ghe.example"],
    environment~,
    config_dir=directory,
    transport~,
  )
  assert_eq(output.exit_code(), 0)
  assert_true(output.stderr().contains("fixture-enterprise"))
  assert_false(output.stderr().contains("enterprise-fixture-token"))
}

///|
async test "auth login delegates OAuth and stores only an account reference in keyring mode" {
  let directory = @fs.tmpdir(prefix="gh-auth-login-")
  defer @fs.rmdir(directory, recursive=true)
  let environment = @github_auth.Environment::new(gh_host="github.com")
  let seen = Ref("")
  let adapter = @native.OAuthAdapter::new(authorize=(host, scopes) => {
    seen.val = host + ":" + scopes
    Ok("oauth-fixture-token")
  })
  let stored : Map[String, String] = Map([])
  let backend = @native.CredentialBackend::new(
    read=(host, user) => stored.get(host + "/" + user),
    write=(host, user, token) => {
      stored[host + "/" + user] = token
      true
    },
    delete=(host, user) => {
      stored.remove(host + "/" + user)
      true
    },
  )
  let output = @native.github_auth_command(
    ["login", "--user", "fixture-user"],
    environment~,
    config_dir=directory,
    credential_backend=backend,
    oauth_adapter=adapter,
    transport=@github.Transport::new(send=_ => {
      Ok(
        @github.RawResponse::new(
          status=200,
          body=b"{\"login\":\"fixture-user\"}",
        ),
      )
    }),
  )
  assert_eq(output.exit_code(), 0)
  assert_true(seen.val.contains("github.com:"))
  assert_eq(stored.get("github.com/fixture-user"), Some("oauth-fixture-token"))
  let source = @fs.read_file(directory + "/hosts.yml").text()
  assert_false(source.contains("oauth-fixture-token"))
  let token = @native.github_auth_command(
    ["token", "--user", "fixture-user"],
    environment~,
    config_dir=directory,
    credential_backend=backend,
  )
  assert_eq(token.stdout(), "oauth-fixture-token\n")
}

///|
async test "auth setup-git passes host-scoped credential helper as argv" {
  let mut seen : Array[String] = []
  let runner : async (Array[String]) -> Result[
    @native.NativeProcessResult,
    @native.ProcessAdapterError,
  ] = args => {
    seen = args
    Ok(@native.NativeProcessResult::new(exit_code=0))
  }
  let output = @native.github_auth_setup_git(
    ["setup-git", "--hostname", "ghe.example"],
    @github_auth.Environment::new(),
    runner~,
  )
  assert_eq(output.exit_code(), 0)
  assert_eq(seen, [
    "config", "--global", "credential.https://ghe.example.helper", "!gh auth git-credential",
  ])
}
