///|
pub struct ReleaseDownloadOptions {
  tag : String?
  patterns : Array[String]
  archive : String
  directory : String
  output : String
  clobber : Bool
  skip_existing : Bool
  allow_escapes : Bool
}

///|
fn release_download_flag_error(message : String) -> Output {
  Output::new(
    exit_code=1,
    stderr=message +
      "\n\n" +
      "Usage:  gh release download [<tag>] [flags]\n\nFlags:\n" +
      "      --allow-escape-sequences   Allow printing terminal escape sequences when writing an asset to standard output\n" +
      "  -A, --archive format           Download the source code archive in the specified format (zip or tar.gz)\n" +
      "      --clobber                  Overwrite existing files of the same name\n" +
      "  -D, --dir directory            The directory to download files into (default \".\")\n" +
      "  -O, --output file              The file to write a single asset to (use \"-\" to write to standard output)\n" +
      "  -p, --pattern stringArray      Download only assets that match a glob pattern\n" +
      "      --skip-existing            Skip downloading when files of the same name exist\n  \n",
  )
}

///|
pub fn parse_release_download(
  options : BusinessOptions,
) -> Result[ReleaseDownloadOptions, Output] {
  let patterns : Array[String] = []
  let positionals : Array[String] = []
  let values : Map[String, String] = Map([])
  let flags : Map[String, Bool] = Map([])
  let args = options.args()
  let mut index = 1
  let mut literal = false
  while index < args.length() {
    let arg = args[index]
    index += 1
    if !literal && arg == "--" {
      literal = true
      continue
    }
    if literal || arg == "-" || !arg.has_prefix("-") {
      positionals.push(arg)
      continue
    }
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
    if flag is ("--clobber" | "--skip-existing" | "--allow-escape-sequences") {
      let enabled = match attached {
        None | Some("true" | "1" | "t" | "TRUE" | "True" | "T") => true
        Some("false" | "0" | "f" | "FALSE" | "False" | "F") => false
        Some(_) =>
          return Err(release_download_flag_error("invalid boolean flag value"))
      }
      flags[flag] = enabled
      continue
    }
    let name = match flag {
      "-p" | "--pattern" => "pattern"
      "-A" | "--archive" => "archive"
      "-O" | "--output" => "output"
      "-D" | "--dir" => "dir"
      "-R" | "--repo" => "repo"
      _ => return Err(release_download_flag_error("unknown flag: " + flag))
    }
    let value = match attached {
      Some(value) => value
      None => {
        guard index < args.length() else {
          return Err(
            release_download_flag_error("flag needs an argument: " + flag),
          )
        }
        let value = args[index]
        index += 1
        value
      }
    }
    if name == "pattern" {
      patterns.push(value)
    } else {
      values[name] = value
    }
  }
  if positionals.length() > 1 {
    return Err(
      Output::new(
        stderr="accepts at most 1 arg(s), received " +
          positionals.length().to_string() +
          "\n",
        exit_code=1,
      ),
    )
  }
  let result : ReleaseDownloadOptions = {
    tag: positionals.get(0),
    patterns,
    archive: values.get("archive").unwrap_or(""),
    directory: values.get("dir").unwrap_or("."),
    output: values.get("output").unwrap_or(""),
    clobber: flags.get("--clobber").unwrap_or(false),
    skip_existing: flags.get("--skip-existing").unwrap_or(false),
    allow_escapes: flags.get("--allow-escape-sequences").unwrap_or(false),
  }
  let error = if result.tag is None &&
    patterns.is_empty() &&
    result.archive.is_empty() {
    Some(
      "`--pattern` or `--archive` is required when downloading the latest release",
    )
  } else if result.clobber && result.skip_existing {
    Some("specify only one of `--clobber` or `--skip-existing`")
  } else if result.directory != "." && !result.output.is_empty() {
    Some("specify only one of `--dir` or `--output`")
  } else if !result.archive.is_empty() && !patterns.is_empty() {
    Some("specify only one of '--pattern' or '--archive'")
  } else if !result.archive.is_empty() &&
    !(result.archive is ("zip" | "tar.gz")) {
    Some("the value for `--archive` must be one of \"zip\" or \"tar.gz\"")
  } else {
    None
  }
  match error {
    Some(message) => Err(release_download_flag_error(message))
    None => Ok(result)
  }
}
