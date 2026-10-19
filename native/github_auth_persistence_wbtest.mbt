///|
fn persistence_existing_account() -> Map[String, LocalYaml] raise {
  local_yaml_parse(
    "github.com:\n  user: fixture\n  users:\n    fixture:\n      git_protocol: https\n",
  )
}

///|
async test "login cancellation after keyring mutation commits its account reference first" {
  let directory = @fs.tmpdir(prefix="gh-persist-cancel-")
  defer @fs.rmdir(directory, recursive=true)
  let mut stored : String? = None
  let mut started = false
  let mut returned = false
  let backend = CredentialBackend::new_async(
    read=(_, _) => stored,
    write=(_, _, token) => {
      stored = Some(token)
      started = true
      @async.sleep(20)
      true
    },
    delete=(_, _) => {
      stored = None
      true
    },
  )
  @async.with_task_group() <| group => {
    let task = group.spawn(() => {
      ignore(
        auth_persist_login(
          directory,
          "github.com",
          "fixture",
          "synthetic-new-token",
          Map([]),
          Some(backend),
          false,
          None,
        ),
      )
      returned = true
    })
    while !started {
      @async.pause()
    }
    task.cancel()
  }
  assert_false(returned)
  assert_eq(stored, Some("synthetic-new-token"))
  let source = @fs.read_file(directory + "/hosts.yml").text()
  assert_true(source.contains("fixture"))
  assert_false(source.contains("synthetic-new-token"))
  assert_false(source.contains("keyring_cleanup_pending"))
}

///|
async test "failed config commit restores old credentials or deletes newly created credentials" {
  for prior in [None, Some("synthetic-old-token")] {
    let directory = @fs.tmpdir(prefix="gh-persist-rollback-")
    defer @fs.rmdir(directory, recursive=true)
    let mut stored = prior
    let mut deletions = 0
    let backend = CredentialBackend::new(
      read=(_, _) => stored,
      write=(_, _, token) => {
        stored = Some(token)
        true
      },
      delete=(_, _) => {
        deletions += 1
        stored = None
        true
      },
    )
    let root = if prior is Some(_) {
      persistence_existing_account()
    } else {
      Map([])
    }
    let original = local_yaml_render(root, "")
    let output = auth_persist_login(
      directory,
      "github.com",
      "fixture",
      "synthetic-new-token",
      root,
      Some(backend),
      false,
      None,
      save=_ => raise LocalConfigError,
    )
    assert_eq(output.exit_code(), 1)
    assert_true(output.stderr().contains("prior credential state was restored"))
    assert_false(output.stderr().contains("synthetic"))
    assert_eq(stored, prior)
    assert_eq(deletions, if prior is None { 1 } else { 0 })
    assert_eq(local_yaml_render(root, ""), original)
  }
}

///|
async test "rollback failures retain recovery references and report sanitized diagnostics" {
  for raises in [false, true] {
    let directory = @fs.tmpdir(prefix="gh-persist-recovery-")
    defer @fs.rmdir(directory, recursive=true)
    let mut calls = 0
    let mut stored = "synthetic-old-token"
    let backend = CredentialBackend::new_async(
      read=(_, _) => Some(stored),
      write=(_, _, token) => {
        calls += 1
        if calls == 1 {
          stored = token
          true
        } else if raises {
          raise LocalConfigError
        } else {
          false
        }
      },
      delete=(_, _) => false,
    )
    let mut saves = 0
    let output = auth_persist_login(
      directory,
      "github.com",
      "fixture",
      "synthetic-new-token",
      persistence_existing_account(),
      Some(backend),
      false,
      None,
      save=values => {
        saves += 1
        if saves == 1 {
          raise LocalConfigError
        }
        local_write_yaml(directory, "hosts.yml", values)
      },
    )
    assert_eq(output.exit_code(), 1)
    assert_true(output.stderr().contains("rollback could not be confirmed"))
    assert_true(output.stderr().contains("recovery account reference was kept"))
    assert_false(output.stderr().contains("synthetic"))
    assert_eq(stored, "synthetic-new-token")
    let source = @fs.read_file(directory + "/hosts.yml").text()
    assert_true(source.contains("keyring_cleanup_pending"))
    assert_false(source.contains("synthetic"))
  }
}

///|
async test "unreadable existing keyring credentials stop login before overwrite or deletion" {
  let mut writes = 0
  let mut deletes = 0
  let mut saves = 0
  let backend = CredentialBackend::new(
    read=(_, _) => None,
    write=(_, _, _) => {
      writes += 1
      true
    },
    delete=(_, _) => {
      deletes += 1
      true
    },
  )
  let output = auth_persist_login(
    "unused",
    "github.com",
    "fixture",
    "synthetic-token",
    persistence_existing_account(),
    Some(backend),
    false,
    None,
    save=_ => saves += 1,
  )
  assert_eq(output.exit_code(), 1)
  assert_true(output.stderr().contains("could not be read"))
  assert_eq((writes, deletes, saves), (0, 0, 0))
}

///|
async test "ambiguous keyring failures mark plaintext recovery and block unconfirmed logout" {
  for behavior in ["false", "error", "timeout"] {
    let directory = @fs.tmpdir(prefix="gh-persist-ambiguous-")
    defer @fs.rmdir(directory, recursive=true)
    let mut stored : String? = None
    let backend = CredentialBackend::new_async(
      read=(_, _) => stored,
      write=(_, _, token) => {
        stored = Some(token)
        if behavior == "error" {
          raise LocalConfigError
        }
        if behavior == "timeout" {
          @async.sleep(60000)
        }
        false
      },
      delete=(_, _) => false,
    )
    let output = auth_persist_login(
      directory,
      "github.com",
      "fixture",
      "synthetic-token",
      Map([]),
      Some(backend),
      false,
      None,
      timeout_ms=30,
    )
    assert_eq(output.exit_code(), 0)
    assert_true(output.stderr().contains("cleanup remains unconfirmed"))
    let source = @fs.read_file(directory + "/hosts.yml").text()
    assert_true(source.contains("keyring_cleanup_pending"))
    assert_true(source.contains("synthetic-token"))
    let logout = github_auth_command(
      ["logout", "--user", "fixture"],
      environment=@github_auth.Environment::new(),
      config_dir=directory,
      credential_backend=backend,
    )
    assert_eq(logout.exit_code(), 1)
    assert_eq(@fs.read_file(directory + "/hosts.yml").text(), source)
    let cleanup = CredentialBackend::new(
      read=(_, _) => stored,
      write=(_, _, _) => false,
      delete=(_, _) => {
        stored = None
        true
      },
    )
    let cleaned = github_auth_command(
      ["logout", "--user", "fixture"],
      environment=@github_auth.Environment::new(),
      config_dir=directory,
      credential_backend=cleanup,
    )
    assert_eq(cleaned.exit_code(), 0)
    assert_eq(stored, None)
    assert_false(
      @fs.read_file(directory + "/hosts.yml").text().contains("fixture"),
    )
  }
}

///|
async test "partial private file writes are removed and CreateNew collisions are preserved" {
  let directory = @fs.tmpdir(prefix="gh-private-file-cleanup-")
  defer @fs.rmdir(directory, recursive=true)
  let temporary = directory + "/.hosts.yml.fixture"
  let destination = directory + "/hosts.yml"
  @fs.write_file(destination, "original")
  let failed = try {
    local_replace_private_file(temporary, destination, "synthetic-token", write=(
      file,
      value,
    ) => {
      file.write(value)
      raise LocalConfigError
    })
    false
  } catch {
    _ => true
  }
  assert_true(failed)
  assert_false(@fs.exists(temporary))
  assert_eq(@fs.read_file(destination).text(), "original")
  @fs.write_file(temporary, "someone-elses-file")
  let collided = try {
    local_replace_private_file(temporary, destination, "synthetic-token")
    false
  } catch {
    _ => true
  }
  assert_true(collided)
  assert_eq(@fs.read_file(temporary).text(), "someone-elses-file")
  assert_eq(@fs.read_file(destination).text(), "original")
}

///|
async test "private file cancellation completes atomic rename and timeout removes partial file" {
  let directory = @fs.tmpdir(prefix="gh-private-file-cancel-")
  defer @fs.rmdir(directory, recursive=true)
  let temporary = directory + "/.hosts.yml.fixture"
  let destination = directory + "/hosts.yml"
  let mut started = false
  @async.with_task_group() <| group => {
    let task = group.spawn(() => {
      local_replace_private_file(temporary, destination, "synthetic-token", write=(
        file,
        value,
      ) => {
        file.write(value)
        started = true
        @async.sleep(20)
      })
    })
    while !started {
      @async.pause()
    }
    task.cancel()
  }
  assert_false(@fs.exists(temporary))
  assert_eq(@fs.read_file(destination).text(), "synthetic-token")
  let timed_out = try {
    local_replace_private_file(
      temporary,
      destination,
      "partial-secret",
      write=(file, value) => {
        file.write(value)
        @async.sleep(60000)
      },
      timeout_ms=20,
    )
    false
  } catch {
    _ => true
  }
  assert_true(timed_out)
  assert_false(@fs.exists(temporary))
  assert_eq(@fs.read_file(destination).text(), "synthetic-token")
}

///|
async test "failed private file rename removes only its owned temporary file" {
  let directory = @fs.tmpdir(prefix="gh-private-file-rename-")
  defer @fs.rmdir(directory, recursive=true)
  let temporary = directory + "/.hosts.yml.fixture"
  let destination = directory + "/hosts.yml"
  @fs.mkdir(destination)
  let failed = try {
    local_replace_private_file(temporary, destination, "synthetic-token")
    false
  } catch {
    _ => true
  }
  assert_true(failed)
  assert_false(@fs.exists(temporary))
  assert_eq(@fs.kind(destination), @fs.Directory)
}

///|
async test "login cancellation before keyring mutation does not write credentials" {
  let mut reading = false
  let mut writes = 0
  let mut saves = 0
  let backend = CredentialBackend::new_async(
    read=(_, _) => {
      reading = true
      @async.sleep(60000)
      None
    },
    write=(_, _, _) => {
      writes += 1
      true
    },
    delete=(_, _) => true,
  )
  @async.with_task_group() <| group => {
    let task = group.spawn(() => {
      ignore(
        auth_persist_login(
          "unused",
          "github.com",
          "fixture",
          "synthetic-token",
          Map([]),
          Some(backend),
          false,
          None,
          save=_ => saves += 1,
        ),
      )
    })
    while !reading {
      @async.pause()
    }
    task.cancel()
  }
  assert_eq((writes, saves), (0, 0))
}

///|
async test "real YAML rename failure rolls back keyring and removes temporary secrets" {
  for prior in [None, Some("synthetic-old-token")] {
    let directory = @fs.tmpdir(prefix="gh-persist-real-rename-")
    defer @fs.rmdir(directory, recursive=true)
    @fs.mkdir(directory + "/hosts.yml")
    let mut stored = prior
    let backend = CredentialBackend::new(
      read=(_, _) => stored,
      write=(_, _, token) => {
        stored = Some(token)
        true
      },
      delete=(_, _) => {
        stored = None
        true
      },
    )
    let output = auth_persist_login(
      directory,
      "github.com",
      "fixture",
      "synthetic-new-token",
      if prior is Some(_) {
        persistence_existing_account()
      } else {
        Map([])
      },
      Some(backend),
      false,
      None,
    )
    assert_eq(output.exit_code(), 1)
    assert_eq(stored, prior)
    assert_eq(@fs.readdir(directory, include_hidden=true), ["hosts.yml"])
  }
}

///|
async test "failed rollback and failed recovery config produce explicit sanitized failure" {
  let mut stored : String? = None
  let backend = CredentialBackend::new(
    read=(_, _) => stored,
    write=(_, _, token) => {
      stored = Some(token)
      true
    },
    delete=(_, _) => false,
  )
  let output = auth_persist_login(
    "unused",
    "github.com",
    "fixture",
    "synthetic-new-token",
    Map([]),
    Some(backend),
    false,
    None,
    save=_ => raise LocalConfigError,
  )
  assert_eq(output.exit_code(), 1)
  assert_true(output.stderr().contains("rollback could not be confirmed"))
  assert_true(output.stderr().contains("recovery reference could not be saved"))
  assert_false(output.stderr().contains("synthetic-new-token"))
}

///|
async test "insecure storage keeps previous keyring reference until confirmed cleanup" {
  let directory = @fs.tmpdir(prefix="gh-persist-insecure-migrate-")
  defer @fs.rmdir(directory, recursive=true)
  let output = auth_persist_login(
    directory,
    "github.com",
    "fixture",
    "synthetic-token",
    persistence_existing_account(),
    None,
    true,
    None,
  )
  assert_eq(output.exit_code(), 0)
  assert_true(output.stderr().contains("cleanup remains unconfirmed"))
  let before = @fs.read_file(directory + "/hosts.yml").text()
  assert_true(before.contains("keyring_cleanup_pending"))
  let logout = github_auth_command(
    ["logout", "--user", "fixture"],
    environment=@github_auth.Environment::new(),
    config_dir=directory,
  )
  assert_eq(logout.exit_code(), 1)
  assert_eq(@fs.read_file(directory + "/hosts.yml").text(), before)
}

///|
test "persistence preserves legacy accounts and other hosts while storing new identity" {
  let original = local_yaml_parse(
    "github.com:\n  user: old-user\n  oauth_token: old-token\nother.example:\n  user: enterprise\n  oauth_token: enterprise-token\n",
  )
  let updated = auth_persist_tree(
    original,
    "github.com",
    "new-user",
    None,
    false,
    Some("ssh"),
  )
  guard updated.get("github.com") is Some(Mapping(values)) else {
    fail("host missing")
  }
  assert_eq(auth_account_names(values), ["new-user", "old-user"])
  assert_eq(auth_account_token(values, "old-user"), Some("old-token"))
  assert_eq(auth_account_token(values, "new-user"), None)
  assert_eq(local_get(values, "git_protocol"), Some("ssh"))
  assert_true(local_yaml_render(updated, "").contains("enterprise-token"))
  assert_false(local_yaml_render(original, "").contains("new-user"))
}

///|
async test "auth login cancellation after keyring store commits verified identity before exit" {
  let directory = @fs.tmpdir(prefix="gh-login-persist-cancel-")
  defer @fs.rmdir(directory, recursive=true)
  let mut stored : String? = None
  let mut started = false
  let mut completed = false
  let backend = CredentialBackend::new_async(
    read=(_, _) => stored,
    write=(_, _, token) => {
      stored = Some(token)
      started = true
      @async.sleep(20)
      true
    },
    delete=(_, _) => {
      stored = None
      true
    },
  )
  @async.with_task_group() <| group => {
    let task = group.spawn(() => {
      ignore(
        github_auth_command(
          ["login"],
          environment=@github_auth.Environment::new(),
          config_dir=directory,
          credential_backend=backend,
          oauth_adapter=OAuthAdapter::new(authorize=(_, _) => {
            Ok("synthetic-login-token")
          }),
          transport=@github.Transport::new(send=_ => {
            Ok(
              @github.RawResponse::new(
                status=200,
                body=b"{\"login\":\"fixture\"}",
              ),
            )
          }),
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
  assert_eq(stored, Some("synthetic-login-token"))
  let config = @fs.read_file(directory + "/hosts.yml").text()
  assert_true(config.contains("fixture"))
  assert_false(config.contains("synthetic-login-token"))
  assert_eq(@fs.readdir(directory, include_hidden=true), ["hosts.yml"])
}
