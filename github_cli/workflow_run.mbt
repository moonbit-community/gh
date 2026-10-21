///|
pub struct WorkflowRunOptions {
  selector : String
  ref_name : String
  raw_fields : Array[String]
  file_fields : Array[String]
  json_input : Bool
}

///|
pub fn parse_workflow_run(
  options : BusinessOptions,
) -> Result[WorkflowRunOptions, Output] {
  let raw_fields : Array[String] = []
  let file_fields : Array[String] = []
  let positionals : Array[String] = []
  let mut ref_name = ""
  let mut json_input = false
  let mut literal = false
  let mut subcommand_seen = false
  let args = options.args()
  let mut index = 0
  while index < args.length() {
    let arg = args[index]
    index += 1
    if !literal && arg == "--" {
      literal = true
      continue
    }
    if !subcommand_seen && arg == "run" {
      subcommand_seen = true
      continue
    }
    if literal || !arg.has_prefix("-") || arg == "-" {
      positionals.push(arg)
      continue
    }
    let (flag, attached) = if arg.has_prefix("--") {
      match arg.split_once("=") {
        Some((flag, value)) => (flag.to_owned(), Some(value.to_owned()))
        None => (arg, None)
      }
    } else if arg.length() > 2 {
      let value = arg[2:].to_owned()
      (
        arg[:2].to_owned(),
        Some(value.strip_prefix("=").map_or(value, value => value.to_owned())),
      )
    } else {
      (arg, None)
    }
    if flag == "--json" {
      match attached {
        None | Some("true") => json_input = true
        Some("false") => json_input = false
        Some(_) =>
          return Err(
            Output::new(stderr="invalid value for --json\n", exit_code=1),
          )
      }
      continue
    }
    guard flag
      is ("-f"
      | "--raw-field"
      | "-F"
      | "--field"
      | "-r"
      | "--ref"
      | "-R"
      | "--repo") else {
      return Err(
        Output::new(stderr="unknown flag: " + flag + "\n", exit_code=1),
      )
    }
    let value = match attached {
      Some(value) => value
      None => {
        guard index < args.length() else {
          return Err(
            Output::new(
              stderr="flag needs an argument: " + flag + "\n",
              exit_code=1,
            ),
          )
        }
        let value = args[index]
        index += 1
        value
      }
    }
    match flag {
      "-f" | "--raw-field" => raw_fields.push(value)
      "-F" | "--field" => file_fields.push(value)
      "-r" | "--ref" => ref_name = value
      _ => ()
    }
  }
  let fields_passed = !raw_fields.is_empty() || !file_fields.is_empty()
  guard positionals.get(0) is Some(selector) else {
    return Err(
      Output::new(
        stderr=(if fields_passed {
            "workflow argument required when passing -f or -F"
          } else {
            "workflow ID, name, or filename required when not running interactively"
          }) +
          "\n",
        exit_code=1,
      ),
    )
  }
  guard !(fields_passed && json_input) else {
    return Err(
      Output::new(
        stderr="only one of STDIN or -f/-F can be passed\n",
        exit_code=1,
      ),
    )
  }
  // v2.102.0's run command uses the first positional selector.
  Ok({ selector, ref_name, raw_fields, file_fields, json_input, })
}

///|
pub fn workflow_input_pair(field : String) -> Result[(String, String), Output] {
  match field.split_once("=") {
    Some((key, value)) => Ok((key.to_owned(), value.to_owned()))
    None =>
      Err(
        Output::new(
          stderr="field " +
            Json(field).stringify() +
            " requires a value separated by an '=' sign\n",
          exit_code=1,
        ),
      )
  }
}

///|
/// gh unmarshals JSON into map[string]string: null values become empty strings,
/// a null root remains null, and other non-string values are rejected.
pub fn workflow_json_inputs(value : Json) -> Result[Json, Output] {
  if value is Null {
    return Ok(Json::null())
  }
  guard value is Object(fields) else {
    return Err(
      Output::new(
        stderr="could not parse provided JSON: expected an object\n",
        exit_code=1,
      ),
    )
  }
  let output : Map[String, Json] = Map([])
  for key, value in fields {
    match value {
      String(_) => output[key] = value
      Null => output[key] = Json("")
      _ => {
        let kind = match value {
          True | False => "bool"
          Number(_) => "number"
          Array(_) => "array"
          _ => "object"
        }
        return Err(
          Output::new(
            stderr="could not parse provided JSON: json: cannot unmarshal " +
              kind +
              " into Go struct field ." +
              key +
              " of type string\n",
            exit_code=1,
          ),
        )
      }
    }
  }
  Ok(Json::object(output))
}
