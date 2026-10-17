///|
/// A bounded result from a native child process. The process adapter owns the
/// pipe plumbing; callers never need to concatenate a shell command string.
pub struct NativeProcessResult {
  exit_code : Int32
  stdout : Bytes
  stderr : Bytes
}

///|
pub fn NativeProcessResult::new(
  exit_code~ : Int32 = 0,
  stdout~ : Bytes = b"",
  stderr~ : Bytes = b"",
) -> NativeProcessResult {
  { exit_code, stdout, stderr, }
}

///|
pub fn NativeProcessResult::exit_code(self : NativeProcessResult) -> Int32 {
  self.exit_code
}

///|
pub fn NativeProcessResult::stdout(self : NativeProcessResult) -> Bytes {
  self.stdout
}

///|
pub fn NativeProcessResult::stderr(self : NativeProcessResult) -> Bytes {
  self.stderr
}

///|
pub suberror ProcessAdapterError {
  InvalidCommand
  InvalidArgument
  OutputLimit
  TimedOut
  Failed
} derive(Debug, Eq)

///|
pub extend ProcessAdapterError with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub extend ProcessAdapterError with Eq::{not_equal, equal}

///|

///|
/// Run a program with an argv array, bounded pipes, and a cancellation-aware
/// timeout. `program` is passed directly to the native process API; no shell
/// is involved, so metacharacters in arguments remain literal bytes.
pub async fn run_native_process(
  program : String,
  args : Array[String],
  input? : Bytes,
  timeout_ms~ : Int32 = 30000,
  max_output_bytes~ : Int32 = 1048576,
) -> Result[NativeProcessResult, ProcessAdapterError] {
  guard !program.is_empty() &&
    !program.iter().any(ch => ch.to_int() < 32 || ch.to_int() == 127) else {
    return Err(InvalidCommand)
  }
  guard args.all(arg => {
    !arg.iter().any(ch => ch.to_int() < 32 || ch.to_int() == 127)
  }) else {
    return Err(InvalidArgument)
  }
  guard timeout_ms > 0 && max_output_bytes > 0 else {
    return Err(InvalidArgument)
  }
  try {
    let (result_code, stdout_bytes, stderr_bytes) = @async.with_timeout(
      timeout_ms,
    ) <| () => {
      let (child_stdin, input_writer) = @process.write_to_process()
      @async.with_task_group() <| group => {
        let writer = group.spawn(() => {
          match input {
            Some(bytes) => input_writer.write(bytes)
            None => ()
          }
          input_writer.close()
        })
        let (code, stdout, stderr) = @process.collect_output(
          program,
          args,
          stdin=child_stdin,
          inherit_env=true,
        )
        writer.wait()
        (code, stdout.binary(), stderr.binary())
      }
    }
    guard stdout_bytes.length() <= max_output_bytes else {
      return Err(ProcessAdapterError::OutputLimit)
    }
    guard stderr_bytes.length() <= max_output_bytes else {
      return Err(ProcessAdapterError::OutputLimit)
    }
    Ok({ exit_code: result_code, stdout: stdout_bytes, stderr: stderr_bytes, })
  } catch {
    error if @async.is_being_cancelled() => raise error
    ProcessAdapterError::OutputLimit => Err(ProcessAdapterError::OutputLimit)
    @async.TimeoutError => Err(TimedOut)
    _ => Err(Failed)
  }
}

///|
/// Parse a configured editor/browser command into an executable and argv.
/// Quotes and backslash escapes are accepted for convenience; shell syntax is
/// never evaluated. An empty command is rejected so callers can fall back to
/// their platform default explicitly.
pub fn split_native_command(
  command : String,
) -> Result[(String, Array[String]), ProcessAdapterError] {
  let parts : Array[String] = []
  let mut current = StringBuilder()
  let mut quote : Char? = None
  let mut escaped = false
  for ch in command {
    if escaped {
      current.write_char(ch)
      escaped = false
      continue
    }
    if ch == '\\' {
      escaped = true
      continue
    }
    match quote {
      Some(open) if ch == open => quote = None
      Some(_) => current.write_char(ch)
      None if ch == '\'' || ch == '"' => quote = Some(ch)
      None if ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r' =>
        if current.to_string() is value && !value.is_empty() {
          parts.push(value)
          current = StringBuilder()
        }
      None => current.write_char(ch)
    }
  }
  guard !escaped && quote is None else { return Err(InvalidCommand) }
  let tail = current.to_string()
  if !tail.is_empty() {
    parts.push(tail)
  }
  guard parts.get(0) is Some(program) && !program.is_empty() else {
    return Err(InvalidCommand)
  }
  Ok((program, parts[1:].to_owned()))
}

///|
/// Run an editor command with a file path appended as one argv element.
pub async fn run_editor(
  command : String,
  path : String,
  timeout_ms~ : Int32 = 300000,
) -> Result[NativeProcessResult, ProcessAdapterError] {
  guard !path.is_empty() &&
    !path.iter().any(ch => ch.to_int() < 32 || ch.to_int() == 127) else {
    return Err(InvalidArgument)
  }
  let (program, args0) = match split_native_command(command) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let args = args0.copy()
  args.push(path)
  run_native_process(program, args, timeout_ms~)
}

///|
/// Run a browser opener with a URL appended as one argv element. URL handling
/// stays in the caller; this adapter only guarantees argv separation.
pub async fn open_browser(
  command : String,
  url : String,
  timeout_ms~ : Int32 = 30000,
) -> Result[NativeProcessResult, ProcessAdapterError] {
  guard !url.is_empty() &&
    !url.iter().any(ch => ch.to_int() < 32 || ch.to_int() == 127) else {
    return Err(InvalidArgument)
  }
  let (program, args0) = match split_native_command(command) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let args = args0.copy()
  args.push(url)
  run_native_process(program, args, timeout_ms~)
}

///|
/// Execute a process attached to the caller's terminal. On a native CLI this
/// preserves an existing PTY and forwards stdin/stdout/stderr directly; the
/// adapter still passes executable and argv separately and never invokes a
/// shell.
pub async fn run_terminal_process(
  program : String,
  args : Array[String],
  timeout_ms~ : Int32 = 300000,
  runner? : async (String, Array[String]) -> Int32,
) -> Result[Int32, ProcessAdapterError] {
  guard !program.is_empty() && timeout_ms > 0 else {
    return Err(InvalidArgument)
  }
  guard !program.iter().any(ch => ch.to_int() < 32 || ch.to_int() == 127) &&
    args.all(arg => {
      !arg.iter().any(ch => ch.to_int() < 32 || ch.to_int() == 127)
    }) else {
    return Err(InvalidArgument)
  }
  try {
    let code = @async.with_timeout(timeout_ms) <| () => {
      match runner {
        Some(run) => run(program, args)
        None =>
          @process.run(
            program,
            args,
            stdin=@stdio.stdin,
            stdout=@stdio.stdout,
            stderr=@stdio.stderr,
            inherit_env=true,
            cancel_handler=@process.hard_cancel(),
          )
      }
    }
    Ok(code)
  } catch {
    error if @async.is_being_cancelled() => raise error
    @async.TimeoutError => Err(TimedOut)
    _ => Err(Failed)
  }
}
