///|
/// gh 2.102.0 uses spinner 1.23.2's 120ms animation around these requests.
/// The upstream MoonBit async/tty adapters own scheduling and terminal I/O;
/// this adapter owns gh's bytes, enablement and cancellation restoration.
async fn[T] with_terminal_progress(
  context : @github_cli.FormatContext,
  write : async (Bytes) -> Unit,
  operation : async () -> T,
  wait~ : async (Int32) -> Unit noraise = @async.sleep,
) -> T {
  if !context.progress_enabled {
    return operation()
  }
  let disabled = match context.environment.get("GH_SPINNER_DISABLED") {
    Some(value) => !["false", "0", "no", ""].contains(value)
    None => {
      let configured = match config_hosts_path() {
        Some(path) => {
          let root = local_read_yaml(
            path.strip_suffix("hosts.yml").unwrap().to_owned() + "config.yml",
          ) catch {
            _ => Map([])
          }
          local_config_value(root, Map([]), None, "spinner") == Some("disabled")
        }
        None => false
      }
      configured || progress_agent_environment(context.environment)
    }
  }
  if disabled {
    write(
      @utf8.encode(
        if context.color {
          "\u001b[0;36mWorking...\u001b[0m\n"
        } else {
          "Working...\n"
        },
      ),
    )
    return operation()
  }
  write(b"\x1b[?25l")
  defer @async.protect_from_cancel(() => {
    write(b"\x1b[?25h\r\x1b[K") catch {
      _ => ()
    }
  })
  let frames = ["⣾", "⣽", "⣻", "⢿", "⡿", "⣟", "⣯", "⣷"]
  async fn frame(index : Int32) -> Unit {
    write(
      @utf8.encode(
        "\r\u001b[K\r" +
        (if context.color {
          "\u001b[36m" + frames[index] + "\u001b[0m"
        } else {
          frames[index]
        }),
      ),
    )
  }
  frame(0)
  @async.with_task_group() <| group => {
    group.spawn_bg(no_wait=true, () => {
      let mut index = 1
      while true {
        wait(120)
        frame(index)
        index = (index + 1) % frames.length()
      }
    })
    operation()
  }
}

///|
fn progress_agent_environment(environment : Map[String, String]) -> Bool {
  if environment.get("AI_AGENT") is Some(value) &&
    !value.is_empty() &&
    value
    .iter()
    .all(ch => ch is ('a'..<='z' | 'A'..<='Z' | '0'..<='9' | '-' | '_')) {
    return true
  }
  if environment.get("AGENT") == Some("amp") ||
    environment.get("TERM_PROGRAM") == Some("kiro") ||
    environment.get("CURSOR_EXTENSION_HOST_ROLE") == Some("agent-exec") {
    return true
  }
  for
    name in [
      "CODEX_SANDBOX", "CODEX_CI", "CODEX_THREAD_ID", "GEMINI_CLI", "COPILOT_CLI",
      "OPENCODE", "ANTIGRAVITY_AGENT", "AUGMENT_AGENT", "REPL_ID", "CLAUDE_CODE_IS_COWORK",
      "CLAUDECODE", "CLAUDE_CODE", "CURSOR_TRACE_ID", "CURSOR_AGENT", "GOOSE_PROVIDER",
    ] {
    if environment.get(name).map_or(false, value => !value.is_empty()) {
      return true
    }
  }
  environment
  .get("PATH")
  .map_or(false, value => {
    value.contains("/.pi/agent") || value.contains("\\.pi\\agent")
  })
}
