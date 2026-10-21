///|
pub struct RunRerunOptions {
  run_id : String
  job_id : String
  only_failed : Bool
  debug_logging : Bool
}

///|
fn actions_boolean(value : String) -> Bool? {
  match value {
    "1" | "t" | "T" | "TRUE" | "true" | "True" => Some(true)
    "0" | "f" | "F" | "FALSE" | "false" | "False" => Some(false)
    _ => None
  }
}

///|
fn rerun_flag_error(message : String) -> Output {
  Output::new(
    stderr=message +
      "\n\nUsage:  gh run rerun [<run-id>] [flags]\n\nFlags:\n  -d, --debug        Rerun with debug logging\n      --failed       Rerun only failed jobs, including dependencies\n  -j, --job string   Rerun a specific job ID from a run, including dependencies\n  \n",
    exit_code=1,
  )
}

///|
pub fn parse_run_rerun(
  options : BusinessOptions,
) -> Result[RunRerunOptions, Output] {
  let args = options.args()
  let positionals : Array[String] = []
  let mut job_id = ""
  let mut only_failed = false
  let mut debug_logging = false
  let mut literal = false
  let mut index = 1
  let mut pending : (String, String)? = None
  while index < args.length() || pending is Some(_) {
    let (arg, original) = match pending {
      Some(value) => {
        pending = None
        value
      }
      None => {
        let value = args[index]
        index += 1
        (value, value)
      }
    }
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
      if arg.has_prefix("-d") && !arg.has_prefix("-d=") {
        pending = Some(("-" + arg[2:].to_owned(), original))
        ("-d", None)
      } else {
        (
          arg[:2].to_owned(),
          Some(arg[2:].strip_prefix("=").unwrap_or(arg[2:]).to_owned()),
        )
      }
    } else {
      (arg, None)
    }
    if flag is ("--failed" | "--debug" | "-d") {
      let value = match attached {
        None => true
        Some(value) =>
          match actions_boolean(value) {
            Some(value) => value
            None =>
              return Err(
                rerun_flag_error(
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
      if flag == "--failed" {
        only_failed = value
      } else {
        debug_logging = value
      }
      continue
    }
    guard flag is ("--job" | "-j" | "--repo" | "-R") else {
      return Err(
        rerun_flag_error(
          if flag.has_prefix("--") {
            "unknown flag: " + flag
          } else {
            "unknown shorthand flag: '" +
            flag[1:].to_owned() +
            "' in " +
            original
          },
        ),
      )
    }
    let value = match attached {
      Some(value) => value
      None => {
        guard index < args.length() else {
          return Err(rerun_flag_error("flag needs an argument: " + flag))
        }
        let value = args[index]
        index += 1
        value
      }
    }
    if flag is ("--job" | "-j") {
      job_id = value
    }
  }
  guard positionals.length() <= 1 else {
    return Err(
      Output::new(
        stderr="accepts at most 1 arg(s), received " +
          positionals.length().to_string() +
          "\n",
        exit_code=1,
      ),
    )
  }
  let run_id = if job_id.is_empty() {
    positionals.get(0).unwrap_or("")
  } else {
    ""
  }
  guard !run_id.is_empty() || !job_id.is_empty() else {
    return Err(
      rerun_flag_error(
        "`<run-id>` or `--job` required when not running interactively",
      ),
    )
  }
  Ok({ run_id, job_id, only_failed, debug_logging, })
}
