///|
pub struct RunDownloadOptions {
  run_id : String?
  directory : String
  names : Array[String]
  patterns : Array[String]
}

///|
pub fn RunDownloadOptions::isolated(self : RunDownloadOptions) -> Bool {
  !self.patterns.is_empty() || self.names.length() != 1
}

///|
pub fn RunDownloadOptions::matches(
  self : RunDownloadOptions,
  name : String,
) -> Bool {
  (self.names.is_empty() && self.patterns.is_empty()) ||
  self.names.contains(name) ||
  self.patterns.any(pattern => download_name_matches(name, pattern))
}

///|
pub fn parse_run_download(
  options : BusinessOptions,
) -> Result[RunDownloadOptions, Output] {
  let names : Array[String] = []
  let patterns : Array[String] = []
  let mut directory = "."
  let mut run_id : String? = None
  let args = options.args()
  let mut subcommand_seen = false
  let mut literal = false
  let mut index = 0
  while index < args.length() {
    let arg = args[index]
    index += 1
    if !literal && arg == "--" {
      literal = true
      continue
    }
    if !subcommand_seen && arg == "download" {
      subcommand_seen = true
      continue
    }
    if !literal && arg.has_prefix("-") {
      let (flag, attached) = if arg.has_prefix("--") {
        match arg.split_once("=") {
          Some((key, value)) => (key.to_owned(), Some(value.to_owned()))
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
      guard flag
        is ("-n"
        | "--name"
        | "-p"
        | "--pattern"
        | "-D"
        | "--dir"
        | "-R"
        | "--repo") else {
        return Err(failure(message="unknown flag: " + flag))
      }
      let value = match attached {
        Some(value) => value
        None => {
          guard index < args.length() else {
            return Err(failure(message="flag needs an argument: " + flag))
          }
          let value = args[index]
          index += 1
          value
        }
      }
      match flag {
        "-n" | "--name" => names.push(value)
        "-p" | "--pattern" => patterns.push(value)
        "-D" | "--dir" => directory = value
        _ => ()
      }
    } else {
      guard run_id is None else {
        return Err(failure(message="accepts at most 1 arg(s), received 2"))
      }
      run_id = Some(arg)
    }
  }
  Ok({ run_id, directory, names, patterns, })
}
