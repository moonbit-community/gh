///|
#cfg(not(platform="windows"))
async test "native process adapter passes argv literally and captures output" {
  let result = @native.run_native_process("printf", [
    "%s", "literal;$(echo should-not-run)",
  ])
  guard result is Ok(value) else { fail("process fixture failed") }
  assert_eq(value.exit_code(), 0)
  assert_eq(value.stdout(), b"literal;$(echo should-not-run)")
  assert_eq(value.stderr(), b"")
}

///|
#cfg(not(platform="windows"))
async test "native process adapter forwards stdin without a shell" {
  let result = @native.run_native_process(
    "cat",
    [],
    input=b"stdin;$(echo should-not-run)",
  )
  guard result is Ok(value) else { fail("stdin process fixture failed") }
  assert_eq(value.exit_code(), 0)
  assert_eq(value.stdout(), b"stdin;$(echo should-not-run)")
}

///|
#cfg(not(platform="windows"))
async test "native process adapter preserves nonzero status and stderr" {
  // `sh` is only a fixture process here; the adapter still receives the
  // executable and every argument separately and never builds a shell string.
  let result = @native.run_native_process("sh", [
    "-c", "printf fixture-error >&2; exit 23",
  ])
  guard result is Ok(value) else { fail("status fixture failed") }
  assert_eq(value.exit_code(), 23)
  assert_eq(value.stdout(), b"")
  assert_eq(value.stderr(), b"fixture-error")
}

///|
#cfg(not(platform="windows"))
async test "native process adapter reports a timed out child" {
  let result = @native.run_native_process("sleep", ["1"], timeout_ms=1)
  assert_true(result is Err(@native.ProcessAdapterError::TimedOut))
}

///|
#cfg(not(platform="windows"))
async test "native process adapter enforces output and argument bounds" {
  let oversized = @native.run_native_process(
    "printf",
    ["%s", "12345"],
    max_output_bytes=2,
  )
  assert_true(oversized is Err(@native.ProcessAdapterError::OutputLimit))
  assert_true(
    @native.run_native_process("printf", ["bad\u{0000}arg"])
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
#cfg(not(platform="windows"))
async test "editor and browser adapters append one argument without a shell" {
  let editor = @native.run_editor("printf %s", "draft;$(echo x)")
  guard editor is Ok(value) else { fail("editor fixture failed") }
  assert_eq(value.exit_code(), 0)
  assert_eq(value.stdout(), b"draft;$(echo x)")

  let browser = @native.open_browser(
    "printf %s", "https://example.test/a?x=$(id)",
  )
  guard browser is Ok(value) else { fail("browser fixture failed") }
  assert_eq(value.exit_code(), 0)
  assert_eq(value.stdout(), b"https://example.test/a?x=$(id)")
}

///|
#cfg(not(platform="windows"))
async test "terminal adapter runs argv directly" {
  let status = @native.run_terminal_process("true", [])
  assert_eq(status, Ok(0))
}

///|
#cfg(not(platform="windows"))
async test "terminal adapter preserves child failure and reports timeout" {
  let failure = @native.run_terminal_process("sh", ["-c", "exit 19"])
  assert_eq(failure, Ok(19))
  let timeout = @native.run_terminal_process("sleep", ["1"], timeout_ms=1)
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
#cfg(not(platform="windows"))
async test "editor and browser adapters enforce bounded native process time" {
  let editor = @native.run_editor(
    "tail -f /dev/null",
    "fixture.md",
    timeout_ms=1,
  )
  assert_true(editor is Err(@native.ProcessAdapterError::TimedOut))
  let browser = @native.open_browser(
    "tail -f /dev/null",
    "https://fixture.test",
    timeout_ms=1,
  )
  assert_true(browser is Err(@native.ProcessAdapterError::TimedOut))
}

///|
#cfg(not(platform="windows"))
async test "editor and browser adapters reject control bytes before spawning" {
  let editor = @native.run_editor("true", "bad\npath")
  assert_true(editor is Err(@native.ProcessAdapterError::InvalidArgument))
  let browser = @native.open_browser("true", "https://fixture.test\u{0000}")
  assert_true(browser is Err(@native.ProcessAdapterError::InvalidArgument))
}

///|
#cfg(not(platform="windows"))
async test "configured editor honors GH_EDITOR without shell expansion" {
  @env.set_env_var("GH_EDITOR", "printf %s")
  defer @env.unset_env_var("GH_EDITOR")
  let command = @native.configured_editor(None)
  assert_eq(command, "printf %s")
  let result = @native.run_configured_editor(
    "draft;$(echo should-not-run)",
    timeout_ms=1000,
  )
  guard result is Ok(value) else { fail("configured editor fixture failed") }
  assert_eq(value.exit_code(), 0)
  assert_eq(value.stdout(), b"draft;$(echo should-not-run)")
}

///|
#cfg(not(platform="windows"))
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

///|
#cfg(platform="windows")
async test "native process adapter uses Windows process fixtures" {
  let result = @native.run_native_process("cmd.exe", [
    "/d", "/c", "echo", "literal;$(echo should-not-run)",
  ])
  guard result is Ok(value) else { fail("Windows process fixture failed") }
  assert_eq(value.exit_code(), 0)
  assert_eq(
    value.stdout().text().trim_end(chars="\r\n"),
    "literal;$(echo should-not-run)",
  )
  let status = @native.run_terminal_process("cmd.exe", ["/d", "/c", "exit", "0"])
  assert_eq(status, Ok(0))
}

///|
#cfg(platform="windows")
async test "editor and browser adapters preserve Windows argv boundaries" {
  let editor = @native.run_editor("cmd.exe /d /c echo", "draft;$(echo x)")
  guard editor is Ok(value) else { fail("Windows editor fixture failed") }
  assert_eq(value.exit_code(), 0)
  let browser = @native.open_browser(
    "cmd.exe /d /c echo", "https://example.test/a?x=$(id)",
  )
  guard browser is Ok(value) else { fail("Windows browser fixture failed") }
  assert_eq(value.exit_code(), 0)
}

///|
#cfg(platform="windows")
async test "browse uses GH_BROWSER on Windows" {
  @env.set_env_var("GH_BROWSER", "cmd.exe /d /c echo")
  defer @env.unset_env_var("GH_BROWSER")
  let output = @native.run_github([
    "browse", "-R", "github.com/acme/demo", "issues?x=$(id)",
  ])
  assert_eq(output.exit_code(), 0)
}
