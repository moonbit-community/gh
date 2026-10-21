///|
pub struct WorkflowManageOptions {
  action : String
  selector : String
  all : Bool
  limit : Int32
  fields : Array[String]?
  jq : String?
  template : String?
}

///|
fn workflow_flag_error(action : String, message : String) -> Output {
  Output::new(
    stderr=message +
      "\n\nUsage:  gh workflow " +
      action +
      (if action == "list" {
        " [flags]\n\nFlags:\n  -a, --all               Include disabled workflows\n  -q, --jq expression     Filter JSON output using a jq expression\n      --json fields       Output JSON with the specified fields\n  -L, --limit int         Maximum number of workflows to fetch (default 50)\n  -t, --template string   Format JSON output using a Go template; see \"gh help formatting\"\n  \n"
      } else {
        " [<workflow-id> | <workflow-name>] [flags]\n"
      }),
    exit_code=1,
  )
}

///|
pub fn parse_workflow_manage(
  options : BusinessOptions,
) -> Result[WorkflowManageOptions, Output] {
  let args = options.args()
  let action = if args.get(0) == Some("ls") {
    "list"
  } else {
    args.get(0).unwrap_or("")
  }
  let list = action == "list"
  let positionals : Array[String] = []
  let mut all = false
  let mut limit = 50
  let mut fields : Array[String]? = None
  let mut jq : String? = None
  let mut template : String? = None
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
      if list && arg.has_prefix("-a") && !arg.has_prefix("-a=") {
        pending = Some(("-" + arg[2:].to_owned(), original))
        ("-a", None)
      } else {
        (
          arg[:2].to_owned(),
          Some(arg[2:].strip_prefix("=").unwrap_or(arg[2:]).to_owned()),
        )
      }
    } else {
      (arg, None)
    }
    if list && flag is ("--all" | "-a") {
      all = match attached {
        None => true
        Some(value) =>
          match actions_boolean(value) {
            Some(value) => value
            None =>
              return Err(
                workflow_flag_error(
                  action,
                  "invalid argument " +
                  Json(value).stringify() +
                  " for \"-a, --all\" flag: strconv.ParseBool: parsing " +
                  Json(value).stringify() +
                  ": invalid syntax",
                ),
              )
          }
      }
      continue
    }
    guard flag is ("--repo" | "-R") ||
      (
        list &&
        flag
        is ("--limit" | "-L" | "--json" | "--jq" | "-q" | "--template" | "-t")
      ) else {
      return Err(
        workflow_flag_error(
          action,
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
          return Err(
            workflow_flag_error(action, "flag needs an argument: " + flag),
          )
        }
        let value = args[index]
        index += 1
        value
      }
    }
    match flag {
      "--all" | "-a" => ()
      "--limit" | "-L" => {
        let parsed = match watch_interval(value) {
          Ok(value) => value
          Err(reason) =>
            return Err(
              workflow_flag_error(
                action,
                "invalid argument " +
                Json(value).stringify() +
                " for \"-L, --limit\" flag: strconv.ParseInt: parsing " +
                Json(value).stringify() +
                ": " +
                reason,
              ),
            )
        }
        // A finite collection is bounded by GitHub pagination; a larger Go int
        // need not narrow to a negative MoonBit int.
        limit = parsed.min(2147483647L).max(-2147483648L).to_int()
      }
      "--json" =>
        fields = Some(
          if value.is_empty() {
            []
          } else {
            value.split(",").map(value => value.to_owned()).collect()
          },
        )
      "--jq" | "-q" => jq = Some(value)
      "--template" | "-t" => template = Some(value)
      _ => ()
    }
  }
  if list && !positionals.is_empty() {
    return Err(
      workflow_flag_error(
        action,
        "unknown command " +
        Json(positionals[0]).stringify() +
        " for \"gh workflow list\"",
      ),
    )
  }
  if !list && positionals.length() > 1 {
    return Err(
      Output::new(
        stderr="accepts at most 1 arg(s), received " +
          positionals.length().to_string() +
          "\n",
        exit_code=1,
      ),
    )
  }
  if fields is Some(fields) {
    let available = "Available fields:\n  id\n  name\n  path\n  state\n"
    for field in fields {
      if !["id", "name", "path", "state"].contains(field) {
        return Err(
          Output::new(
            stderr="Unknown JSON field: " +
              Json(field).stringify() +
              "\n" +
              available,
            exit_code=1,
          ),
        )
      }
    }
  } else if jq.map_or(false, value => !value.is_empty()) ||
    template.map_or(false, value => !value.is_empty()) {
    return Err(
      Output::new(
        stderr="cannot use `--" +
          (if jq.map_or(false, value => !value.is_empty()) {
            "jq"
          } else {
            "template"
          }) +
          "` without specifying `--json`\n",
        exit_code=1,
      ),
    )
  }
  if list && limit < 1 {
    return Err(
      workflow_flag_error(action, "invalid limit: " + limit.to_string()),
    )
  }
  let selector = positionals.get(0).unwrap_or("")
  if !list && selector.is_empty() {
    return Err(
      workflow_flag_error(
        action, "workflow ID or name required when not running interactively",
      ),
    )
  }
  Ok({ action, selector, all, limit, fields, jq, template, })
}
