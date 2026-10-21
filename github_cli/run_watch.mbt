///|
pub struct RunWatchOptions {
  run_id : String
  interval : Int64
  exit_status : Bool
  compact : Bool
}

///|
fn watch_flag_error(message : String) -> Output {
  Output::new(
    stderr=message +
      "\n\nUsage:  gh run watch <run-id> [flags]\n\nFlags:\n      --compact        Show only relevant/failed steps\n      --exit-status    Exit with non-zero status if run fails\n  -i, --interval int   Refresh interval in seconds (default 3)\n  \n",
    exit_code=1,
  )
}

///|
pub fn parse_run_watch(
  options : BusinessOptions,
) -> Result[RunWatchOptions, Output] {
  let args = options.args()
  let positionals : Array[String] = []
  let mut interval = 3L
  let mut compact = false
  let mut exit_status = false
  let mut literal = false
  let mut index = 1
  while index < args.length() {
    let arg = args[index]
    index += 1
    if !literal && arg == "--" {
      literal = true
      continue
    }
    if literal || !arg.has_prefix("-") || arg == "-" {
      positionals.push(arg)
      continue
    }
    let (flag, attached) = if arg.has_prefix("--") {
      match arg.split_once("=") {
        Some((key, value)) => (key.to_owned(), Some(value.to_owned()))
        None => (arg, None)
      }
    } else if arg.length() > 2 {
      (
        arg[:2].to_owned(),
        Some(arg[2:].strip_prefix("=").unwrap_or(arg[2:]).to_owned()),
      )
    } else {
      (arg, None)
    }
    if flag is ("--compact" | "--exit-status") {
      let value = match attached {
        None => true
        Some(value) =>
          match actions_boolean(value) {
            Some(value) => value
            None =>
              return Err(
                watch_flag_error(
                  "invalid argument " +
                  Json(value).stringify() +
                  " for " +
                  Json(flag).stringify() +
                  " flag: strconv.ParseBool: parsing " +
                  Json(value).stringify() +
                  ": invalid syntax",
                ),
              )
          }
      }
      if flag == "--compact" {
        compact = value
      } else {
        exit_status = value
      }
      continue
    }
    guard flag is ("--interval" | "-i" | "--repo" | "-R") else {
      return Err(
        watch_flag_error(
          if flag.has_prefix("--") {
            "unknown flag: " + flag
          } else {
            "unknown shorthand flag: '" + flag[1:].to_owned() + "' in " + arg
          },
        ),
      )
    }
    let value = match attached {
      Some(value) => value
      None => {
        guard index < args.length() else {
          return Err(watch_flag_error("flag needs an argument: " + flag))
        }
        let value = args[index]
        index += 1
        value
      }
    }
    if flag is ("--interval" | "-i") {
      interval = match watch_interval(value) {
        Ok(number) => number
        Err(reason) =>
          return Err(
            watch_flag_error(
              "invalid argument " +
              Json(value).stringify() +
              " for \"-i, --interval\" flag: strconv.ParseInt: parsing " +
              Json(value).stringify() +
              ": " +
              reason,
            ),
          )
      }
    }
  }
  guard positionals.get(0) is Some(run_id) else {
    return Err(
      watch_flag_error("run ID required when not running interactively"),
    )
  }
  Ok({ run_id, interval, exit_status, compact, })
}

///|
/// pflag uses Go's base-zero integers: a leading zero is octal. MoonBit's
/// parser already handles the explicit bases and separators; adapt only the
/// legacy octal spelling and preserve its syntax/range distinction.
fn watch_interval(value : String) -> Result[Int64, String] {
  let (sign, digits) = if value.has_prefix("-") || value.has_prefix("+") {
    (value[:1].to_owned(), value[1:].to_owned())
  } else {
    ("", value)
  }
  let normalized = if digits.length() > 1 &&
    digits.has_prefix("0") &&
    !(digits[1] is ('x' | 'X' | 'o' | 'O' | 'b' | 'B')) {
    sign + "0o" + digits[1:].to_owned()
  } else {
    value
  }
  Ok(@string.parse_int64(normalized)) catch {
    Failure(message) => Err(message)
    _ => Err("invalid syntax")
  }
}

///|
fn watch_style(
  value : String,
  code : String,
  context : FormatContext,
) -> String {
  let code = match code {
    "1" => "0;1;39"
    "0;90" =>
      if context.environment
        .get("TERM")
        .map_or(false, value => value.contains("256color")) {
        "38;5;242"
      } else {
        "0;90"
      }
    _ => "0;" + code
  }
  if context.color {
    "\u001b[" + code + "m" + value + "\u001b[0m"
  } else {
    value
  }
}

///|
pub fn render_watch_refresh(
  interval : Int64,
  context : FormatContext,
) -> String {
  watch_style(
    "Refreshing run status every " +
    interval.to_string() +
    " seconds. Press Ctrl+C to quit.",
    "1",
    context,
  ) +
  "\n\n"
}

///|
pub fn workflow_symbol(
  status : String,
  conclusion : String,
  context : FormatContext,
) -> String {
  let (symbol, color) = if status != "completed" {
    ("*", "33")
  } else {
    match conclusion {
      "success" => ("✓", "32")
      "skipped" | "neutral" => ("-", "0;90")
      _ => ("X", "31")
    }
  }
  watch_style(symbol, color, context)
}

///|
fn watch_ago(timestamp : String, now : Int64) -> String {
  let unix = match @formatter_common.parse_rfc3339(timestamp) {
    Ok((date, offset)) => date.to_unix_second() - offset.to_int64()
    Err(_) => -62135596800L
  }
  let elapsed = now - unix
  if elapsed < 60L {
    return "less than a minute ago"
  }
  let (number, unit) = if elapsed < 3600L {
    (elapsed / 60L, "minute")
  } else if elapsed < 86400L {
    (elapsed / 3600L, "hour")
  } else if elapsed < 2592000L {
    (elapsed / 86400L, "day")
  } else if elapsed < 31536000L {
    (elapsed / 2592000L, "month")
  } else {
    (elapsed / 31536000L, "year")
  }
  number.to_string() +
  " " +
  unit +
  (if number == 1L { "" } else { "s" }) +
  " ago"
}

///|
fn watch_elapsed(job : @operations.WorkflowJob) -> String {
  fn instant(value : String) -> (Int64, Int32) {
    match @formatter_common.parse_rfc3339(value) {
      Ok((date, offset)) =>
        (date.to_unix_second() - offset.to_int64(), date.nanosecond())
      Err(_) => (-62135596800L, 0)
    }
  }
  let (start, start_nano) = instant(job.started_at)
  let (end, end_nano) = instant(job.completed_at)
  let mut seconds = end - start
  let mut nanos = end_nano - start_nano
  if nanos < 0 {
    seconds -= 1L
    nanos += 1000000000
  }
  if seconds < 0 {
    return ""
  }
  // time.Time.Sub saturates at the maximum signed nanosecond duration.
  if seconds > 9223372036L || (seconds == 9223372036L && nanos > 854775807) {
    seconds = 9223372036L
    nanos = 854775807
  }
  if seconds == 0L && nanos > 0 {
    let (unit, scale, width) = if nanos < 1000 {
      ("ns", 1, 0)
    } else if nanos < 1000000 {
      ("µs", 1000, 3)
    } else {
      ("ms", 1000000, 6)
    }
    let remainder = nanos % scale
    let fraction = if remainder == 0 {
      ""
    } else {
      "." +
      ("0".repeat(width - remainder.to_string().length()) +
      remainder.to_string())
      .trim_end(chars="0")
      .to_owned()
    }
    return " in " + (nanos / scale).to_string() + fraction + unit
  }
  let hours = seconds / 3600L
  let minutes = seconds % 3600L / 60L
  let seconds = seconds % 60L
  let fraction = if nanos == 0 {
    ""
  } else {
    "." +
    ("0".repeat(9 - nanos.to_string().length()) + nanos.to_string())
    .trim_end(chars="0")
    .to_owned()
  }
  " in " +
  (if hours > 0L { hours.to_string() + "h" } else { "" }) +
  (if minutes > 0L || hours > 0L { minutes.to_string() + "m" } else { "" }) +
  seconds.to_string() +
  fraction +
  "s"
}

///|
pub fn render_watch_completed(
  run : @operations.WorkflowRun,
  context : FormatContext,
  already~ : Bool = false,
) -> String {
  (if already {
    "Run "
  } else {
    "\n" + workflow_symbol(run.status, run.conclusion, context) + " Run "
  }) +
  watch_style(run.workflow_name, "1", context) +
  " (" +
  watch_style(run.id, "36", context) +
  ") " +
  (if already { "has already completed" } else { "completed" }) +
  " with '" +
  run.conclusion +
  "'\n"
}

///|
pub fn render_watch_frame(
  run : @operations.WorkflowRun,
  jobs : Array[@operations.WorkflowJob],
  annotations : Array[@operations.WorkflowAnnotation]?,
  options : RunWatchOptions,
  context : FormatContext,
  pull_request~ : String = "",
) -> String {
  let out = StringBuilder()
  out.write_string(
    workflow_symbol(run.status, run.conclusion, context) +
    " " +
    watch_style(run.head_branch, "1", context) +
    " " +
    run.workflow_name +
    pull_request +
    " · " +
    watch_style(run.id, "36", context) +
    "\nTriggered via " +
    run.event +
    " " +
    watch_ago(run.started_at, context.now_unix) +
    "\n\n",
  )
  if jobs.is_empty() {
    return out.to_string()
  }
  out.write_string(watch_style("JOBS", "1", context) + "\n")
  for job in jobs {
    out.write_string(
      workflow_symbol(job.status, job.conclusion, context) +
      " " +
      watch_style(job.name, "1", context) +
      watch_elapsed(job) +
      " (ID " +
      watch_style(job.id, "36", context) +
      ")\n",
    )
    if options.compact &&
      job.status == "completed" &&
      job.conclusion == "success" {
      continue
    }
    let mut running = ""
    for step in job.steps {
      let line = "  " +
        workflow_symbol(step.status, step.conclusion, context) +
        " " +
        step.name +
        "\n"
      if !options.compact || @operations.workflow_failed(step.conclusion) {
        out.write_string(line)
      }
      if options.compact && step.status == "in_progress" {
        running = line
      }
    }
    out.write_string(running)
  }
  match annotations {
    None =>
      out.write_string(
        "\n" +
        watch_style("ANNOTATIONS", "1", context) +
        "\nrequesting annotations returned 403 Forbidden as the token does not have sufficient permissions. Note that it is not currently possible to create a fine-grained PAT with the `checks:read` permission.",
      )
    Some(items) => {
      if !items.is_empty() {
        out.write_string("\n" + watch_style("ANNOTATIONS", "1", context) + "\n")
      }
      for item in items {
        let symbol = match item.level {
          "failure" => watch_style("X", "31", context)
          "warning" => watch_style("!", "33", context)
          _ => "-"
        }
        out.write_string(
          symbol +
          " " +
          item.message +
          "\n" +
          watch_style(
            item.job_name +
            ": " +
            item.path +
            "#" +
            item.start_line.to_string() +
            "\n",
            "0;90",
            context,
          ) +
          "\n",
        )
      }
    }
  }
  out.to_string()
}
