///|
async test "keyring helpers store read and erase isolated account credentials over stdin" {
  for
    helper in [
      SecretService("fixture-secret-tool"),
      MacOSKeychain,
      WindowsCredentialManager,
    ] {
    let mut stored : String? = None
    let calls : Array[String] = []
    let backend = keyring_backend(helper, run=request => {
      let input = @utf8.decode(request.input)
      assert_false(request.args.any(arg => arg.contains("fixture-token")))
      assert_false(request.program.contains("fixture-token"))
      let operation = if helper is SecretService(_) {
        request.args[0]
      } else {
        request.args[3]
      }
      calls.push(operation)
      if helper is SecretService(_) {
        assert_eq(request.program, "fixture-secret-tool")
        assert_true(request.args.contains("github-cli"))
        assert_true(request.args.contains("github.com"))
        assert_true(request.args.contains("fixture-user"))
      } else {
        assert_eq(request.program, "git")
        assert_eq(
          request.args[2],
          if helper is MacOSKeychain {
            "credential-osxkeychain"
          } else {
            "credential-wincred"
          },
        )
        assert_eq(request.args[0], "-c")
        assert_eq(request.args[1], "alias." + request.args[2] + "=")
        assert_true(
          input.has_prefix(
            "protocol=https\nhost=github.com\npath=gh-moonbit\nusername=fixture-user\n",
          ),
        )
        assert_true(input.has_suffix("\n\n"))
      }
      match operation {
        "store" => {
          assert_true(input.contains("fixture-token"))
          stored = Some("fixture-token")
          Ok(NativeProcessResult::new())
        }
        "erase" | "clear" => {
          assert_false(input.contains("fixture-token"))
          stored = None
          Ok(NativeProcessResult::new())
        }
        _ => {
          let output = match stored {
            None => ""
            Some(token) =>
              if helper is SecretService(_) {
                token + "\n"
              } else {
                "username=fixture-user\npassword=" + token + "\n"
              }
          }
          Ok(NativeProcessResult::new(stdout=@utf8.encode(output)))
        }
      }
    })
    assert_eq(backend.read_async("github.com", "fixture-user"), None)
    assert_true(
      backend.write_async("github.com", "fixture-user", "fixture-token"),
    )
    assert_eq(
      backend.read_async("github.com", "fixture-user"),
      Some("fixture-token"),
    )
    assert_true(backend.delete_async("github.com", "fixture-user"))
    assert_eq(stored, None)
    assert_eq(calls.length(), 6)
  }
}

///|
async test "keyring reports missing helper and rejects silent store or erase failures" {
  let unavailable = keyring_backend(MacOSKeychain, run=_ => Err(Failed))
  assert_eq(unavailable.read_async("github.com", "fixture"), None)
  assert_false(unavailable.write_async("github.com", "fixture", "token"))
  assert_false(unavailable.delete_async("github.com", "fixture"))
  let empty = keyring_backend(MacOSKeychain, run=_ => {
    Ok(NativeProcessResult::new())
  })
  assert_false(empty.write_async("github.com", "fixture", "token"))
  let stale = keyring_backend(WindowsCredentialManager, run=_ => {
    Ok(NativeProcessResult::new(stdout=b"password=old-token\n"))
  })
  assert_false(stale.write_async("github.com", "fixture", "new-token"))
  assert_false(stale.delete_async("github.com", "fixture"))
  let rejected = keyring_backend(SecretService("fixture"), run=_ => {
    Ok(
      NativeProcessResult::new(
        exit_code=2,
        stderr=b"do not expose fixture-token",
      ),
    )
  })
  assert_eq(rejected.read_async("github.com", "fixture"), None)
  assert_false(rejected.write_async("github.com", "fixture", "token"))
  assert_false(rejected.delete_async("github.com", "fixture"))
}

///|
async test "keyring rejects protocol injection before invoking any helper" {
  let mut calls = 0
  let backend = keyring_backend(MacOSKeychain, run=_ => {
    calls += 1
    Ok(NativeProcessResult::new())
  })
  for
    value in [
      "", "user\npassword=attacker", "user\r", "user\u0000", "user name",
    ] {
    assert_eq(backend.read_async("github.com", value), None)
    assert_false(backend.write_async("github.com", value, "token"))
    assert_false(backend.delete_async(value, "fixture"))
    assert_false(backend.write_async("github.com", "fixture", value))
  }
  assert_eq(backend.read_async("--help", "fixture"), None)
  assert_eq(calls, 0)
}

///|
test "keyring parser rejects invalid bytes duplicate passwords and wrong accounts" {
  for
    output in [
      b"password=one\npassword=two\n", b"username=other\npassword=token\n", b"password=bad token\n",
      b"password=\n", b"password=\xff\n",
    ] {
    assert_true(
      keyring_parse(
        MacOSKeychain,
        NativeProcessResult::new(stdout=output),
        "fixture",
      )
      is Err(_),
    )
  }
  assert_eq(
    keyring_parse(
      MacOSKeychain,
      NativeProcessResult::new(stdout=b"password=token=literal\r\n"),
      "fixture",
    ),
    Ok(Some("token=literal")),
  )
  assert_eq(
    keyring_parse(
      SecretService("fixture"),
      NativeProcessResult::new(exit_code=1),
      "fixture",
    ),
    Ok(None),
  )
  assert_true(
    keyring_parse(
      SecretService("fixture"),
      NativeProcessResult::new(stdout=b"two\nlines"),
      "fixture",
    )
    is Err(_),
  )
  assert_true(
    keyring_parse(
      SecretService("fixture"),
      NativeProcessResult::new(exit_code=1, stderr=b"suppressed"),
      "fixture",
    )
    is Err(_),
  )
  assert_true(
    keyring_parse(
      MacOSKeychain,
      NativeProcessResult::new(stderr=b"suppressed"),
      "fixture",
    )
    is Err(_),
  )
}

///|
test "keyring environment excludes authentication tracing and loader overrides" {
  let source : Map[String, String] = {
    "PATH": "fixture-path",
    "HOME": "fixture-home",
    "DBUS_SESSION_BUS_ADDRESS": "fixture-session",
    "GH_TOKEN": "fixture-token",
    "GITHUB_TOKEN": "fixture-token",
    "GH_OAUTH_CLIENT_SECRET": "fixture-client-secret",
    "GIT_TRACE": "fixture-trace-path",
    "GIT_TRACE2_EVENT": "fixture-event-path",
    "GIT_EXEC_PATH": "fixture-helper-override",
    "GIT_ASKPASS": "fixture-askpass",
    "LD_PRELOAD": "fixture-loader",
    "DYLD_INSERT_LIBRARIES": "fixture-loader",
  }
  let environment = keyring_environment(name => source.get(name))
  assert_eq(environment.get("PATH"), Some("fixture-path"))
  assert_eq(
    environment.get("DBUS_SESSION_BUS_ADDRESS"),
    Some("fixture-session"),
  )
  assert_eq(environment.get("GIT_TRACE"), Some("0"))
  assert_eq(environment.get("GIT_TRACE2_EVENT"), Some("0"))
  for
    name in [
      "GH_TOKEN", "GITHUB_TOKEN", "GH_OAUTH_CLIENT_SECRET", "GIT_EXEC_PATH", "GIT_ASKPASS",
      "LD_PRELOAD", "DYLD_INSERT_LIBRARIES",
    ] {
    assert_eq(environment.get(name), None)
  }
}

///|
async test "keyring cancellation never returns a write fallback result" {
  let mut started = false
  let mut returned = false
  let backend = keyring_backend(MacOSKeychain, run=_ => {
    started = true
    @async.sleep(60000)
    Ok(NativeProcessResult::new())
  })
  @async.with_task_group() <| group => {
    let task = group.spawn(() => {
      ignore(backend.write_async("github.com", "fixture", "fixture-token"))
      returned = true
    })
    while !started {
      @async.pause()
    }
    task.cancel()
  }
  assert_true(started)
  assert_false(returned)
}

///|
async test "keyring backend does not access any store when environment token wins" {
  let mut calls = 0
  let backend = keyring_backend(MacOSKeychain, run=_ => {
    calls += 1
    Err(Failed)
  })
  guard resolve_github_auth_with_backend(
      @github_auth.Environment::new(gh_token="fixture-environment-token"),
      backend,
    )
    is Ok(config) else {
    fail("environment authentication failed")
  }
  assert_true(config.token() is Some(_))
  assert_eq(calls, 0)
}

///|
async test "keyring process returns unavailable when helper executable is missing" {
  let directory = @fs.tmpdir(prefix="gh-keyring-missing-helper-")
  defer @fs.rmdir(directory, recursive=true)
  let result = keyring_run({
    program: directory + "/does-not-exist",
    args: [],
    input: b"fixture-token",
  })
  assert_true(result is Err(Failed))
}

///|
#cfg(not(platform="windows"))
async test "keyring process bounds stdout without a shell" {
  // Existing system tools receive only synthetic test bytes. This test never
  // invokes a credential helper or accesses the host credential service.
  let result = keyring_run({
    program: "printf",
    args: ["fixture-output"],
    input: b"",
  })
  guard result is Ok(value) else { fail("printf fixture failed") }
  assert_eq(value.stdout(), b"fixture-output")
  let overflow = keyring_run({
    program: "yes",
    args: ["synthetic-fixture-output"],
    input: b"",
  })
  assert_true(overflow is Err(OutputLimit))
}

///|
async test "keyring pipe drain discards stderr and bounds its allocation" {
  let reader = @io.MemoryReader(writer => {
    writer.write(b"diagnostic containing synthetic-fixture-token")
  })
  defer reader.close()
  assert_eq(
    keyring_capture(reader, false),
    b"credential helper diagnostic suppressed",
  )
  let overflowing = @io.MemoryReader(writer => writer.write("x".repeat(65537)))
  defer overflowing.close()
  let bounded = try {
    ignore(keyring_capture(overflowing, false))
    false
  } catch {
    ProcessAdapterError::OutputLimit => true
    _ => false
  }
  assert_true(bounded)
}

///|
async test "keyring stdout parser enforces readback capacity even for injected providers" {
  let bytes = @utf8.encode("x".repeat(65537))
  assert_true(
    keyring_parse(
      MacOSKeychain,
      NativeProcessResult::new(stdout=bytes),
      "fixture",
    )
    is Err(_),
  )
}

///|
async test "keyring Git dispatch does not execute configured aliases for missing helpers" {
  // An innocuous built-in command stands in for a hostile repository alias.
  // No credential helper is invoked and no OS credential service is touched.
  let command = "codex-gh-keyring-missing-test-helper-9f6c34"
  let configured_alias = ["-c", "alias." + command + "=version"]
  let ordinary_args = configured_alias.copy()
  ordinary_args.append([command])
  guard keyring_run({ program: "git", args: ordinary_args, input: b"", })
    is Ok(ordinary) else {
    fail("Git fixture could not run")
  }
  assert_eq(ordinary.exit_code(), 0)
  assert_true(@utf8.decode(ordinary.stdout()).has_prefix("git version "))
  let protected_args = configured_alias.copy()
  protected_args.append(keyring_git_args(command, "get"))
  guard keyring_run({ program: "git", args: protected_args, input: b"", })
    is Ok(blocked_alias) else {
    fail("Git fixture could not run")
  }
  assert_true(blocked_alias.exit_code() != 0)
  assert_eq(blocked_alias.stdout(), b"")
  assert_eq(blocked_alias.stderr(), b"credential helper diagnostic suppressed")
}
