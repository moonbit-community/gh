///|
async test "native process adapter passes argv literally and captures output" {
  let result = @native.run_native_process("/usr/bin/printf", [
    "%s", "literal;$(echo should-not-run)",
  ])
  guard result is Ok(value) else { fail("process fixture failed") }
  assert_eq(value.exit_code(), 0)
  assert_eq(value.stdout(), b"literal;$(echo should-not-run)")
  assert_eq(value.stderr(), b"")
}

///|
async test "native process adapter forwards stdin without a shell" {
  let result = @native.run_native_process(
    "/usr/bin/cat",
    [],
    input=b"stdin;$(echo should-not-run)",
  )
  guard result is Ok(value) else { fail("stdin process fixture failed") }
  assert_eq(value.exit_code(), 0)
  assert_eq(value.stdout(), b"stdin;$(echo should-not-run)")
}

///|
async test "native process adapter preserves nonzero status and stderr" {
  // `sh` is only a fixture process here; the adapter still receives the
  // executable and every argument separately and never builds a shell string.
  let result = @native.run_native_process("/usr/bin/sh", [
    "-c", "printf fixture-error >&2; exit 23",
  ])
  guard result is Ok(value) else { fail("status fixture failed") }
  assert_eq(value.exit_code(), 23)
  assert_eq(value.stdout(), b"")
  assert_eq(value.stderr(), b"fixture-error")
}

///|
async test "native process adapter reports a timed out child" {
  let result = @native.run_native_process("/usr/bin/sleep", ["1"], timeout_ms=1)
  assert_true(result is Err(@native.ProcessAdapterError::TimedOut))
}

///|
async test "native process adapter enforces output and argument bounds" {
  let oversized = @native.run_native_process(
    "/usr/bin/printf",
    ["%s", "12345"],
    max_output_bytes=2,
  )
  assert_true(oversized is Err(@native.ProcessAdapterError::OutputLimit))
  assert_true(
    @native.run_native_process("/usr/bin/printf", ["bad\u{0000}arg"])
    is Err(@native.ProcessAdapterError::InvalidArgument),
  )
}

///|
test "native command splitting retains quoted argument boundaries" {
  assert_eq(
    @native.split_native_command("editor --wait 'a file.md'"),
    Ok(("editor", ["--wait", "a file.md"])),
  )
  assert_true(@native.split_native_command("editor 'unterminated") is Err(_))
  assert_true(@native.split_native_command("") is Err(_))
}

///|
async test "editor and browser adapters append one argument without a shell" {
  let editor = @native.run_editor("/usr/bin/printf %s", "draft;$(echo x)")
  guard editor is Ok(value) else { fail("editor fixture failed") }
  assert_eq(value.exit_code(), 0)
  assert_eq(value.stdout(), b"draft;$(echo x)")

  let browser = @native.open_browser(
    "/usr/bin/printf %s", "https://example.test/a?x=$(id)",
  )
  guard browser is Ok(value) else { fail("browser fixture failed") }
  assert_eq(value.exit_code(), 0)
  assert_eq(value.stdout(), b"https://example.test/a?x=$(id)")
}

///|
async test "terminal adapter runs argv directly" {
  let status = @native.run_terminal_process("/usr/bin/true", [])
  assert_eq(status, Ok(0))
}

///|
async test "terminal adapter preserves child failure and reports timeout" {
  let failure = @native.run_terminal_process("/usr/bin/sh", ["-c", "exit 19"])
  assert_eq(failure, Ok(19))
  let timeout = @native.run_terminal_process(
    "/usr/bin/sleep",
    ["1"],
    timeout_ms=1,
  )
  assert_true(timeout is Err(@native.ProcessAdapterError::TimedOut))
}

///|
async test "terminal adapter exposes a PTY-safe argv fixture seam" {
  let seen : Ref[(String, Array[String])?] = Ref(None)
  let runner : async (String, Array[String]) -> Int32 = (program, args) => {
    seen.val = Some((program, args))
    27
  }
  let result = @native.run_terminal_process(
    "fixture-pty",
    ["--prompt", "literal;$(echo no-shell)"],
    runner~,
  )
  assert_eq(result, Ok(27))
  assert_eq(
    seen.val,
    Some(("fixture-pty", ["--prompt", "literal;$(echo no-shell)"])),
  )
}

///|
async test "editor and browser adapters enforce bounded native process time" {
  let editor = @native.run_editor(
    "/usr/bin/tail -f /dev/null",
    "fixture.md",
    timeout_ms=1,
  )
  assert_true(editor is Err(@native.ProcessAdapterError::TimedOut))
  let browser = @native.open_browser(
    "/usr/bin/tail -f /dev/null",
    "https://fixture.test",
    timeout_ms=1,
  )
  assert_true(browser is Err(@native.ProcessAdapterError::TimedOut))
}

///|
async test "editor and browser adapters reject control bytes before spawning" {
  let editor = @native.run_editor("/usr/bin/true", "bad\npath")
  assert_true(editor is Err(@native.ProcessAdapterError::InvalidArgument))
  let browser = @native.open_browser(
    "/usr/bin/true", "https://fixture.test\u{0000}",
  )
  assert_true(browser is Err(@native.ProcessAdapterError::InvalidArgument))
}

///|
async test "configured editor honors GH_EDITOR without shell expansion" {
  @env.set_env_var("GH_EDITOR", "/usr/bin/printf %s")
  defer @env.unset_env_var("GH_EDITOR")
  let command = @native.configured_editor(None)
  assert_eq(command, "/usr/bin/printf %s")
  let result = @native.run_configured_editor(
    "draft;$(echo should-not-run)",
    timeout_ms=1000,
  )
  guard result is Ok(value) else { fail("configured editor fixture failed") }
  assert_eq(value.exit_code(), 0)
  assert_eq(value.stdout(), b"draft;$(echo should-not-run)")
}

///|
async test "browse uses GH_BROWSER argv and preserves URL punctuation" {
  let directory = @fs.tmpdir(prefix="gh-browser-fixture-")
  defer @fs.rmdir(directory, recursive=true)
  let captured = directory + "/url.txt"
  let command = directory + "/browser-fixture"
  @fs.write_file(
    command,
    "#!/bin/sh\nprintf '%s' \"$1\" > \"" + captured + "\"\n",
    permission=0o700,
  )
  @env.set_env_var("GH_BROWSER", command)
  defer @env.unset_env_var("GH_BROWSER")
  let output = @native.run_github([
    "browse", "-R", "github.com/acme/demo", "issues?x=$(id)",
  ])
  assert_eq(output.exit_code(), 0)
  assert_eq(
    @fs.read_file(captured).text(),
    "https://github.com/acme/demo/issues%3Fx%3D%24%28id%29",
  )
}
