///|
// Reuse upstream OS credential helpers instead of maintaining bindings to
// libsecret, Security.framework, or Win32. Their stdin protocols keep tokens
// out of argv. No suitable keyring abstraction is present in our MoonBit
// dependencies; the process adapter is the only project-owned mechanism.
priv enum KeyringHelper {
  SecretService(String)
  MacOSKeychain
  WindowsCredentialManager
}

///|
// Deliberately not Debug/Show: a request may contain a credential on stdin.
priv struct KeyringRequest {
  program : String
  args : Array[String]
  input : Bytes
}

///|
fn keyring_field_valid(value : String, max_length : Int32) -> Bool {
  !value.is_empty() &&
  value.length() <= max_length &&
  !value.iter().any(ch => ch.to_int() <= 32 || ch.to_int() == 127)
}

///|
fn keyring_git_args(command : String, operation : String) -> Array[String] {
  // Empty aliases suppress fallback only; Git still resolves an installed
  // external helper before considering the alias.
  ["-c", "alias." + command + "=", command, operation]
}

///|
fn keyring_request(
  helper : KeyringHelper,
  operation : String,
  host : String,
  user : String,
  token : String?,
) -> KeyringRequest? {
  guard keyring_field_valid(host, 512) &&
    keyring_field_valid(user, 256) &&
    !host.has_prefix("-") &&
    !user.has_prefix("-") else {
    return None
  }
  if token is Some(value) && !keyring_field_valid(value, 32768) {
    return None
  }
  match helper {
    SecretService(command) => {
      let args = match operation {
        "get" => ["lookup"]
        "store" => ["store", "--label=GitHub CLI credential"]
        "erase" => ["clear"]
        _ => return None
      }
      args.append(["service", "github-cli", "host", host, "user", user])
      Some({
        program: command,
        args,
        input: @utf8.encode(token.map(value => value + "\n").unwrap_or("")),
      })
    }
    MacOSKeychain | WindowsCredentialManager => {
      let command = match helper {
        MacOSKeychain => "credential-osxkeychain"
        _ => "credential-wincred"
      }
      let input = "protocol=https\nhost=" +
        host +
        "\npath=gh-moonbit\nusername=" +
        user +
        "\n" +
        token.map(value => "password=" + value + "\n").unwrap_or("") +
        "\n"
      Some({
        program: "git",
        // A missing external helper must not fall back to a repository's
        // same-named Git alias, which could execute a shell with token stdin.
        args: keyring_git_args(command, operation),
        input: @utf8.encode(input),
      })
    }
  }
}

///|
// Copy only OS session information required to find the helper and unlock the
// user's credential service. In particular GH_TOKEN, askpass, Git tracing,
// custom Git executable paths, and dynamic loader overrides are not inherited.
fn keyring_environment(get : (String) -> String?) -> Map[String, String] {
  let result : Map[String, String] = Map([])
  for
    name in [
      "PATH", "HOME", "USER", "LOGNAME", "USERPROFILE", "APPDATA", "LOCALAPPDATA",
      "SystemRoot", "SYSTEMROOT", "WINDIR", "TEMP", "TMP", "DBUS_SESSION_BUS_ADDRESS",
      "XDG_RUNTIME_DIR", "DISPLAY", "WAYLAND_DISPLAY", "LANG", "LC_ALL", "LC_CTYPE",
    ] {
    if get(name) is Some(value) {
      result[name] = value
    }
  }
  result["GIT_TERMINAL_PROMPT"] = "0"
  result["GIT_CONFIG_NOSYSTEM"] = "1"
  result["GIT_CONFIG_GLOBAL"] = if @async.platform is Windows {
    "NUL"
  } else {
    "/dev/null"
  }
  result["GIT_TRACE"] = "0"
  result["GIT_TRACE2"] = "0"
  result["GIT_TRACE2_EVENT"] = "0"
  result["GIT_TRACE2_PERF"] = "0"
  result
}

///|
async fn keyring_capture(reader : &@io.Reader, capture : Bool) -> Bytes {
  let buffer = @buffer.Buffer()
  let mut length = 0
  while reader.read_some(max_len=4096) is Some(bytes) {
    length += bytes.length()
    guard length <= 65536 else { raise ProcessAdapterError::OutputLimit }
    if capture {
      buffer.write_bytes(bytes)
    }
  }
  // Only preserve whether stderr was present, never its contents. A helper
  // that reports an error with exit 0 must not pass read-back verification.
  if !capture && length > 0 {
    b"credential helper diagnostic suppressed"
  } else {
    buffer.to_bytes()
  }
}

///|
// The process result is inspected as data before credential storage changes.
#warnings("-result_error_return")
async fn keyring_run(
  request : KeyringRequest,
  timeout_ms~ : Int32 = 5000,
) -> Result[NativeProcessResult, ProcessAdapterError] {
  guard acceptance_process_allowed(request.program, request.args) else {
    return Err(InvalidCommand)
  }
  guard !request.program.is_empty() &&
    !request.program.iter().any(ch => ch.to_int() < 32 || ch.to_int() == 127) else {
    return Err(InvalidCommand)
  }
  guard request.args.all(arg => {
      !arg.iter().any(ch => ch.to_int() < 32 || ch.to_int() == 127)
    }) &&
    request.input.length() <= 65536 &&
    timeout_ms > 0 else {
    return Err(InvalidArgument)
  }
  try
    @async.with_timeout(timeout_ms) <| () => {
      let (child_stdin, writer) = @process.write_to_process()
      let (out_reader, child_stdout) = @process.read_from_process()
      defer out_reader.close()
      let (err_reader, child_stderr) = @process.read_from_process()
      defer err_reader.close()
      @async.with_task_group() <| group => {
        let process = group.spawn(() => {
          @process.run(
            request.program,
            request.args,
            stdin=child_stdin,
            stdout=child_stdout,
            stderr=child_stderr,
            extra_env=keyring_environment(@env.get_env_var),
            inherit_env=false,
            cancel_handler=@process.hard_cancel(),
            no_console_window=true,
          )
        })
        let input = group.spawn(() => {
          defer writer.close()
          writer.write(request.input)
        })
        // Leave pipes open until group cancellation has stopped the helper.
        // Closing here can make SIGPIPE replace OutputLimit on Linux.
        let stdout = group.spawn(() => keyring_capture(out_reader, true))
        // A helper may include credential material in a diagnostic. Drain
        // bounded stderr but never retain or return it.
        let stderr = group.spawn(() => keyring_capture(err_reader, false))
        let exit_code = process.wait()
        input.wait()
        let output = stdout.wait()
        let diagnostic = stderr.wait()
        Ok(
          NativeProcessResult::new(exit_code~, stdout=output, stderr=diagnostic),
        )
      }
    }
  catch {
    error if @async.is_being_cancelled() => raise error
    ProcessAdapterError::OutputLimit => Err(OutputLimit)
    @async.TimeoutError => Err(TimedOut)
    _ => Err(Failed)
  }
}

///|
// Browser and clipboard adapters need the same bounded, secret-free process
// environment. A private wrapper shares it without exposing keyring details.
#warnings("-result_error_return")
async fn auth_host_process(
  program : String,
  args : Array[String],
  input : Bytes,
) -> Result[NativeProcessResult, ProcessAdapterError] {
  keyring_run({ program, args, input, })
}

///|
fn keyring_parse(
  helper : KeyringHelper,
  result : NativeProcessResult,
  user : String,
) -> Result[String?, Unit] {
  // secret-tool uses 1 for a lookup miss. Other helper failures are not
  // interpreted as an empty credential during read-back verification.
  guard result.stderr().is_empty() else { return Err(()) }
  if helper is SecretService(_) && result.exit_code() == 1 {
    return Ok(None)
  }
  guard result.exit_code() == 0 && result.stdout().length() <= 65536 else {
    return Err(())
  }
  let output = @utf8.decode(result.stdout()) catch { _ => return Err(()) }
  match helper {
    SecretService(_) => {
      let token = output.trim_end(chars="\r\n").to_owned()
      if token.is_empty() {
        Ok(None)
      } else if keyring_field_valid(token, 32768) {
        Ok(Some(token))
      } else {
        Err(())
      }
    }
    _ => {
      let mut token : String? = None
      for line in output.split("\n") {
        let line = line.trim_end(chars="\r")
        if line.has_prefix("username=") && line[9:] != user {
          return Err(())
        }
        if line.has_prefix("password=") {
          let value = line[9:].to_owned()
          guard token is None && keyring_field_valid(value, 32768) else {
            return Err(())
          }
          token = Some(value)
        }
      }
      Ok(token)
    }
  }
}

///|
async fn keyring_read(
  helper : KeyringHelper,
  host : String,
  user : String,
  run : async (KeyringRequest) -> Result[
    NativeProcessResult,
    ProcessAdapterError,
  ],
) -> Result[String?, Unit] {
  guard keyring_request(helper, "get", host, user, None) is Some(request) else {
    return Err(())
  }
  let result = run(request) catch {
    error if @async.is_being_cancelled() => raise error
    _ => return Err(())
  }
  match result {
    Ok(result) => keyring_parse(helper, result, user)
    Err(_) => Err(())
  }
}

///|
fn keyring_backend(
  helper : KeyringHelper,
  run~ : async (KeyringRequest) -> Result[
    NativeProcessResult,
    ProcessAdapterError,
  ] = request => keyring_run(request),
) -> CredentialBackend {
  CredentialBackend::new_async(
    read=(host, user) => {
      match keyring_read(helper, host, user, run) {
        Ok(token) => token
        Err(_) => None
      }
    },
    write=(host, user, token) => {
      guard keyring_request(helper, "store", host, user, Some(token))
        is Some(request) else {
        return false
      }
      let stored = run(request) catch {
        error if @async.is_being_cancelled() => raise error
        _ => return false
      }
      guard stored is Ok(result) &&
        result.exit_code() == 0 &&
        result.stderr().is_empty() else {
        return false
      }
      // Some Git helper versions report success even when the OS rejected
      // the write. Only report secure storage after an exact read-back.
      keyring_read(helper, host, user, run) is Ok(Some(actual)) &&
      actual == token
    },
    delete=(host, user) => {
      guard keyring_request(helper, "erase", host, user, None) is Some(request) else {
        return false
      }
      let deleted = run(request) catch {
        error if @async.is_being_cancelled() => raise error
        _ => return false
      }
      guard deleted is Ok(result) &&
        result.exit_code() == 0 &&
        result.stderr().is_empty() else {
        return false
      }
      keyring_read(helper, host, user, run) is Ok(None)
    },
  )
}

///|
/// Linux Secret Service using libsecret's `secret-tool`. Token input uses a
/// private pipe, never argv; a successful write is verified by reading back.
/// Missing helpers and rejected operations return None/false. Cancellation
/// propagates so login cannot turn cancellation into a plaintext fallback.
pub fn secret_tool_backend(
  command~ : String = "secret-tool",
) -> CredentialBackend {
  keyring_backend(SecretService(command))
}

///|
/// Select the native OS store: Linux Secret Service, macOS Keychain through
/// Git's osxkeychain helper, or Windows Credential Manager through Git's
/// wincred helper. Helpers must be installed separately. Git records use the
/// dedicated `gh-moonbit` path and never overwrite ordinary Git credentials.
/// GH_KEYRING_COMMAND is a legacy secret-tool-compatible executable override,
/// not a shell command. Unavailable stores return failure to the auth layer,
/// which must warn if it falls back to plaintext hosts.yml.
pub fn system_credential_backend() -> CredentialBackend {
  if @env.get_env_var("GH_KEYRING_COMMAND") is Some(command) {
    return secret_tool_backend(command~)
  }
  match @async.platform {
    Linux => keyring_backend(SecretService("secret-tool"))
    MacOS => keyring_backend(MacOSKeychain)
    Windows => keyring_backend(WindowsCredentialManager)
  }
}
