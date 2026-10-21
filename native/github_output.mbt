///|
/// Shared formatting bridge for API and business commands.
fn render_github_response(
  status : Int32,
  headers : Array[(String, String)],
  body : Bytes,
  jq? : String,
  template? : String,
  include_headers~ : Bool = false,
  silent~ : Bool = false,
  verbose~ : Bool = false,
  allow_escape_sequences~ : Bool = false,
) -> @github_cli.Output {
  @github_cli.render_response(
    status,
    headers,
    body,
    jq?,
    template?,
    include_headers~,
    silent~,
    verbose~,
    allow_escape_sequences~,
    format_context=process_format_context(),
  )
}

///|
fn process_format_context() -> @github_cli.FormatContext {
  let forced = @env.get_env_var("GH_FORCE_TTY")
  let detected = @tty.isatty(@stdio.stdout) catch { _ => false }
  let terminal = forced.map_or(detected, value => !value.is_empty())
  let measured = if detected {
    try {
      let handle = @tty.Tty::stdio()
      defer handle.close()
      handle.window_size().cols.max(1)
    } catch {
      _ => 80
    }
  } else {
    80
  }
  let width = match forced {
    Some(value) if value.has_suffix("%") => {
      let ratio = @string.parse_int(value[:value.length() - 1]) catch {
        _ => 100
      }
      (measured * ratio / 100).max(1)
    }
    Some(value) => @string.parse_int(value) catch { _ => measured }
    None => measured
  }
  let color = if @env.get_env_var("NO_COLOR").map_or(false, value => {
      !value.is_empty()
    }) ||
    @env.get_env_var("CLICOLOR") == Some("0") {
    false
  } else {
    @env.get_env_var("CLICOLOR_FORCE").map_or(false, value => {
      !value.is_empty() && value != "0"
    }) ||
    (terminal && @env.get_env_var("TERM") != Some("dumb"))
  }
  @github_cli.FormatContext::new(
    terminal~,
    progress_enabled=detected &&
      (@tty.isatty(@stdio.stderr) catch { _ => false }),
    color~,
    width~,
    now_unix=@env.now().reinterpret_as_int64() / 1000L,
    local_zone?=local_format_zone(),
    environment=@env.get_env_vars(),
  )
}

///|
fn local_format_zone() -> @time.Zone? {
  let path = match @env.get_env_var("TZ") {
    Some("" | "UTC" | "Etc/UTC") => return Some(@time.utc_zone)
    Some(name) => {
      guard !name.has_prefix("/") &&
        !name.contains("..") &&
        name
        .iter()
        .all(ch => {
          ch is ('a'..<='z' | 'A'..<='Z' | '0'..<='9' | '/' | '_' | '-' | '+')
        }) else {
        return None
      }
      "/usr/share/zoneinfo/" + name
    }
    None => "/etc/localtime"
  }
  try {
    let bytes = @sync_fs.read_file_to_bytes(path)
    if bytes.length() > 1048576 {
      return None
    }
    Some(@time.Zone::from_tzif2("Local", bytes.to_fixedarray()))
  } catch {
    _ => None
  }
}
