///|
async test "auth switch rotates active account and compatibility token" {
  let directory = @fs.tmpdir(prefix="gh-auth-switch-fixture-")
  defer @fs.rmdir(directory, recursive=true)
  @fs.write_file(
    directory + "/hosts.yml",
    (
      #|github.com:
      #|  user: alice
      #|  oauth_token: alice-token
      #|  users:
      #|    alice:
      #|      oauth_token: alice-token
      #|    bob:
      #|      oauth_token: bob-token
    ),
  )
  let output = @native.github_auth_command(
    ["switch", "--hostname", "github.com", "--user", "bob"],
    environment=@github_auth.Environment::new(),
    config_dir=directory,
  )
  assert_eq(output.exit_code(), 0)
  assert_eq(
    output.stdout(),
    "✓ Switched active account for github.com to bob\n",
  )
  let source = @fs.read_file(directory + "/hosts.yml").text()
  assert_true(source.contains("\"user\": \"bob\""))
  assert_true(source.contains("\"oauth_token\": \"bob-token\""))
  let token = @native.github_auth_command(
    ["token"],
    environment=@github_auth.Environment::new(),
    config_dir=directory,
  )
  assert_eq(token.stdout(), "bob-token\n")
}

///|
async test "auth logout selects the next account and removes the host last" {
  let directory = @fs.tmpdir(prefix="gh-auth-logout-fixture-")
  defer @fs.rmdir(directory, recursive=true)
  @fs.write_file(
    directory + "/hosts.yml",
    (
      #|github.com:
      #|  user: alice
      #|  oauth_token: alice-token
      #|  users:
      #|    alice:
      #|      oauth_token: alice-token
      #|    bob:
      #|      oauth_token: bob-token
    ),
  )
  let first = @native.github_auth_command(
    ["logout", "--hostname", "github.com", "--user", "alice"],
    environment=@github_auth.Environment::new(),
    config_dir=directory,
  )
  assert_eq(first.exit_code(), 0)
  assert_true(first.stdout().contains("account alice"))
  let source = @fs.read_file(directory + "/hosts.yml").text()
  assert_true(source.contains("\"user\": \"bob\""))
  assert_true(source.contains("\"oauth_token\": \"bob-token\""))
  let second = @native.github_auth_command(
    ["logout", "--hostname", "github.com", "--user", "bob"],
    environment=@github_auth.Environment::new(),
    config_dir=directory,
  )
  assert_eq(second.exit_code(), 0)
  let empty = @fs.read_file(directory + "/hosts.yml").text()
  assert_false(empty.contains("github.com"))
}

///|
test "credential and OAuth adapters are injectable without secret formatting" {
  let backend = @native.CredentialBackend::new(
    read=(host, user) => {
      if host == "github.com" && user == "fixture" {
        Some("fixture-token")
      } else {
        None
      }
    },
    write=(_, _, token) => token == "fixture-token",
    delete=(_, _) => true,
  )
  assert_eq(backend.read("github.com", "fixture"), Some("fixture-token"))
  assert_true(backend.write("github.com", "fixture", "fixture-token"))
  assert_true(backend.delete("github.com", "fixture"))
  let adapter = @native.OAuthAdapter::new(authorize=(host, scopes) => {
    if host == "github.com" && scopes == "repo,read:org" {
      Ok("oauth-fixture-token")
    } else {
      Err(@native.OAuthError::Failed)
    }
  })
  assert_eq(
    adapter.authorize("github.com", "repo,read:org"),
    Ok("oauth-fixture-token"),
  )
}

///|
async test "async OAuth adapter can suspend and still keeps token out of diagnostics" {
  let seen = Ref("")
  let adapter = @native.OAuthAdapter::new_async(authorize=(host, scopes) => {
    @async.sleep(1)
    seen.val = host + ":" + scopes
    Ok("oauth-async-fixture-token")
  })
  let result = adapter.authorize_async("github.com", "repo,workflow")
  assert_eq(result, Ok("oauth-async-fixture-token"))
  assert_eq(seen.val, "github.com:repo,workflow")
  assert_eq(
    adapter.authorize("github.com", "repo"),
    Err(@native.OAuthError::Unavailable),
  )
}

///|
async test "auth token can resolve an injected keyring credential" {
  let directory = @fs.tmpdir(prefix="gh-auth-keyring-fixture-")
  defer @fs.rmdir(directory, recursive=true)
  @fs.write_file(
    directory + "/hosts.yml",
    (
      #|github.com:
      #|  user: keyring-user
      #|  users:
      #|    keyring-user:
      #|      git_protocol: https
    ),
  )
  let backend = @native.CredentialBackend::new(
    read=(host, user) => {
      if host == "github.com" && user == "keyring-user" {
        Some("keyring-fixture-token")
      } else {
        None
      }
    },
    write=(_, _, _) => true,
    delete=(_, _) => true,
  )
  let output = @native.github_auth_command(
    ["token"],
    environment=@github_auth.Environment::new(),
    config_dir=directory,
    credential_backend=backend,
  )
  assert_eq(output.exit_code(), 0)
  assert_eq(output.stdout(), "keyring-fixture-token\n")
  assert_eq(output.stderr(), "")
}

///|
async test "async credential backend participates in account resolution" {
  let directory = @fs.tmpdir(prefix="gh-auth-async-keyring-fixture-")
  defer @fs.rmdir(directory, recursive=true)
  @fs.write_file(
    directory + "/hosts.yml",
    (
      #|github.com:
      #|  user: async-user
      #|  users:
      #|    async-user:
      #|      git_protocol: https
    ),
  )
  let backend = @native.CredentialBackend::new_async(
    read=(host, user) => {
      if host == "github.com" && user == "async-user" {
        Some("async-keyring-token")
      } else {
        None
      }
    },
    write=(_, _, _) => true,
    delete=(_, _) => true,
  )
  let output = @native.github_auth_command(
    ["token"],
    environment=@github_auth.Environment::new(),
    config_dir=directory,
    credential_backend=backend,
  )
  assert_eq(output.exit_code(), 0)
  assert_eq(output.stdout(), "async-keyring-token\n")
}

///|
async test "missing secret tool returns unavailable without exposing credential input" {
  let directory = @fs.tmpdir(prefix="gh-secret-tool-missing-")
  defer @fs.rmdir(directory, recursive=true)
  let command = directory + "/does-not-exist"
  let backend = @native.secret_tool_backend(command~)
  assert_eq(backend.read_async("github.com", "fixture"), None)
  assert_false(backend.write_async("github.com", "fixture", "write-secret"))
  assert_false(backend.delete_async("github.com", "fixture"))
}

///|
async test "auth logout preserves keyring account when delete cannot be confirmed" {
  let directory = @fs.tmpdir(prefix="gh-keyring-logout-")
  defer @fs.rmdir(directory, recursive=true)
  let source = "github.com:\n  user: fixture\n  users:\n    fixture:\n      git_protocol: https\n"
  @fs.write_file(directory + "/hosts.yml", source)
  let backend = @native.CredentialBackend::new(
    read=(_, _) => Some("fixture-token"),
    write=(_, _, _) => true,
    delete=(_, _) => false,
  )
  let output = @native.github_auth_command(
    ["logout", "--hostname", "github.com", "--user", "fixture"],
    environment=@github_auth.Environment::new(),
    config_dir=directory,
    credential_backend=backend,
  )
  assert_eq(output.exit_code(), 1)
  assert_true(output.stderr().contains("account configuration was kept"))
  assert_false(output.stderr().contains("fixture-token"))
  assert_eq(@fs.read_file(directory + "/hosts.yml").text(), source)
  let unavailable = @native.github_auth_command(
    ["logout", "--hostname", "github.com", "--user", "fixture"],
    environment=@github_auth.Environment::new(),
    config_dir=directory,
  )
  assert_eq(unavailable.exit_code(), 1)
  assert_eq(@fs.read_file(directory + "/hosts.yml").text(), source)
}

///|
async test "auth logout removes keyring account only after backend confirms deletion" {
  let directory = @fs.tmpdir(prefix="gh-keyring-logout-success-")
  defer @fs.rmdir(directory, recursive=true)
  @fs.write_file(
    directory + "/hosts.yml",
    "github.com:\n  user: fixture\n  users:\n    fixture:\n      git_protocol: https\n",
  )
  let mut deleted = false
  let backend = @native.CredentialBackend::new(
    read=(_, _) => Some("fixture-token"),
    write=(_, _, _) => true,
    delete=(host, user) => {
      deleted = host == "github.com" && user == "fixture"
      deleted
    },
  )
  let output = @native.github_auth_command(
    ["logout", "--hostname", "github.com", "--user", "fixture"],
    environment=@github_auth.Environment::new(),
    config_dir=directory,
    credential_backend=backend,
  )
  assert_eq(output.exit_code(), 0)
  assert_true(deleted)
  assert_false(
    @fs.read_file(directory + "/hosts.yml").text().contains("github.com"),
  )
}

///|
async test "auth logout cancellation preserves the keyring account reference" {
  let directory = @fs.tmpdir(prefix="gh-keyring-logout-cancel-")
  defer @fs.rmdir(directory, recursive=true)
  let source = "github.com:\n  user: fixture\n  users:\n    fixture:\n      git_protocol: https\n"
  @fs.write_file(directory + "/hosts.yml", source)
  let mut started = false
  let mut completed = false
  let backend = @native.CredentialBackend::new_async(
    read=(_, _) => Some("fixture-token"),
    write=(_, _, _) => true,
    delete=(_, _) => {
      started = true
      @async.sleep(60000)
      true
    },
  )
  @async.with_task_group() <| group => {
    let task = group.spawn(() => {
      ignore(
        @native.github_auth_command(
          ["logout", "--hostname", "github.com", "--user", "fixture"],
          environment=@github_auth.Environment::new(),
          config_dir=directory,
          credential_backend=backend,
        ),
      )
      completed = true
    })
    while !started {
      @async.pause()
    }
    task.cancel()
  }
  assert_false(completed)
  assert_eq(@fs.read_file(directory + "/hosts.yml").text(), source)
}
