///|
fn login_identity(
  login : String,
  scopes~ : String = "repo, read:org, gist",
) -> @github.Transport {
  @github.Transport::new(send=request => {
    assert_eq(request.path(), "/user")
    Ok(
      @github.RawResponse::new(
        status=200,
        headers=[("X-OAuth-Scopes", scopes)],
        body=@utf8.encode(Json::object({ "login": Json(login) }).stringify()),
      ),
    )
  })
}

///|
async test "auth login resolves verified identity and warns about plaintext fallback" {
  let directory = @fs.tmpdir(prefix="gh-login-identity-")
  defer @fs.rmdir(directory, recursive=true)
  let output = @native.github_auth_command(
    ["login", "--web", "--git-protocol", "https"],
    environment=@github_auth.Environment::new(),
    config_dir=directory,
    oauth_adapter=@native.OAuthAdapter::new(authorize=(_, _) => {
      Ok("private-fixture-token")
    }),
    transport=login_identity("alice"),
    credential_backend=@native.CredentialBackend::new(
      read=(_, _) => None,
      write=(_, _, _) => false,
      delete=(_, _) => true,
    ),
  )
  assert_eq(output.exit_code(), 0)
  assert_true(output.stdout().contains("account alice"))
  assert_true(output.stderr().contains("plain text"))
  assert_false(output.stdout().contains("private-fixture-token"))
  assert_false(output.stderr().contains("private-fixture-token"))
  let yaml = @fs.read_file(directory + "/hosts.yml").text()
  assert_true(yaml.contains("alice"))
  assert_false(yaml.contains("default"))
}

///|
async test "auth login rejects unverifiable and mismatched identities before storage" {
  for
    (response, args) in [
      (@github.RawResponse::new(status=401, body=b"private-token"), ["login"]),
      (@github.RawResponse::new(status=200, body=b"{}"), ["login"]),
      (
        @github.RawResponse::new(status=200, body=b"{\"login\":\"bob\"}"),
        ["login", "--user", "alice"],
      ),
    ] {
    let directory = @fs.tmpdir(prefix="gh-login-invalid-")
    defer @fs.rmdir(directory, recursive=true)
    let writes = Ref(0)
    let output = @native.github_auth_command(
      args,
      environment=@github_auth.Environment::new(),
      config_dir=directory,
      oauth_adapter=@native.OAuthAdapter::new(authorize=(_, _) => {
        Ok("private-token")
      }),
      transport=@github.Transport::new(send=_ => Ok(response)),
      credential_backend=@native.CredentialBackend::new(
        read=(_, _) => None,
        write=(_, _, _) => {
          writes.val += 1
          true
        },
        delete=(_, _) => true,
      ),
    )
    assert_true(output.exit_code() != 0)
    assert_eq(writes.val, 0)
    assert_false(output.stderr().contains("private-token"))
    assert_false(@fs.exists(directory + "/hosts.yml"))
  }
}

///|
async test "auth login honors insecure storage and environment precedence" {
  let directory = @fs.tmpdir(prefix="gh-login-policy-")
  defer @fs.rmdir(directory, recursive=true)
  let writes = Ref(0)
  let authorizations = Ref(0)
  let adapter = @native.OAuthAdapter::new(authorize=(_, _) => {
    authorizations.val += 1
    Ok("synthetic-token")
  })
  let backend = @native.CredentialBackend::new(
    read=(_, _) => None,
    write=(_, _, _) => {
      writes.val += 1
      true
    },
    delete=(_, _) => true,
  )
  let rejected = @native.github_auth_command(
    ["login"],
    environment=@github_auth.Environment::new(
      gh_token="environment-fixture-token",
    ),
    config_dir=directory,
    oauth_adapter=adapter,
    credential_backend=backend,
  )
  assert_true(rejected.exit_code() != 0)
  assert_eq(authorizations.val, 0)
  let output = @native.github_auth_command(
    ["login", "--insecure-storage"],
    environment=@github_auth.Environment::new(),
    config_dir=directory,
    oauth_adapter=adapter,
    credential_backend=backend,
    transport=login_identity("alice"),
  )
  assert_eq(output.exit_code(), 0)
  assert_eq(writes.val, 0)
  assert_true(output.stderr().contains("--insecure-storage"))
}

///|
async test "auth refresh preserves added scopes supports remove reset and protects identity" {
  for
    (flags, expected) in [
      (
        ["--scopes", "project", "--remove-scopes", "workflow,repo"],
        "repo,read:org,gist,project",
      ),
      (["--reset-scopes"], "repo,read:org,gist"),
      ([], "repo,read:org,gist,workflow"),
    ] {
    let directory = @fs.tmpdir(prefix="gh-refresh-policy-")
    defer @fs.rmdir(directory, recursive=true)
    @fs.write_file(
      directory + "/hosts.yml",
      "github.com:\n  user: alice\n  users:\n    alice:\n      oauth_token: prior-token\n",
    )
    let actual = Ref("")
    let args = ["refresh"]
    args.append(flags)
    let output = @native.github_auth_command(
      args,
      environment=@github_auth.Environment::new(),
      config_dir=directory,
      oauth_adapter=@native.OAuthAdapter::new(authorize=(_, scopes) => {
        actual.val = scopes
        Ok("updated-token")
      }),
      transport=login_identity("alice", scopes="repo,read:org,gist,workflow"),
    )
    assert_eq(output.exit_code(), 0)
    assert_eq(actual.val, expected)
  }
  let directory = @fs.tmpdir(prefix="gh-refresh-mismatch-")
  defer @fs.rmdir(directory, recursive=true)
  let original = "github.com:\n  user: alice\n  users:\n    alice:\n      oauth_token: prior-token\n"
  @fs.write_file(directory + "/hosts.yml", original)
  let calls = Ref(0)
  let output = @native.github_auth_command(
    ["refresh"],
    environment=@github_auth.Environment::new(),
    config_dir=directory,
    oauth_adapter=@native.OAuthAdapter::new(authorize=(_, _) => Ok("bob-token")),
    transport=@github.Transport::new(send=_ => {
      calls.val += 1
      Ok(
        @github.RawResponse::new(
          status=200,
          body=if calls.val == 1 {
            b"{\"login\":\"alice\"}"
          } else {
            b"{\"login\":\"bob\"}"
          },
        ),
      )
    }),
  )
  assert_true(output.exit_code() != 0)
  assert_eq(@fs.read_file(directory + "/hosts.yml").text(), original)
}
