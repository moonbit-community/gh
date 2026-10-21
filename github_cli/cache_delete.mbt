///|
pub struct CacheDeleteOptions {
  identifier : String
  cache_id : String?
  ref_name : String
  all : Bool
  succeed_on_empty : Bool
}

///|
/// Match Go's decimal int64 syntax before converting; oversized numbers remain
/// keys, while signs and leading zeroes are canonicalized for the ID endpoint.
pub fn cache_identifier_id(value : String) -> String? {
  let digits = if value.has_prefix("+") || value.has_prefix("-") {
    value[1:]
  } else {
    value[:]
  }
  guard !digits.is_empty() && digits.iter().all(ch => ch is ('0'..<='9')) else {
    return None
  }
  let parsed = @string.parse_int64(value) catch { _ => return None }
  Some(parsed.to_string())
}

///|
fn cache_delete_flag_error(message : String) -> Output {
  Output::new(
    stderr=message +
      "\n\nUsage:  gh cache delete [<cache-id> | <cache-key> | --all] [flags]\n\nFlags:\n  -a, --all                          Delete all caches, can be used with --ref to delete all caches for a specific ref\n  -r, --ref string                   Delete by cache key and ref, formatted as refs/heads/<branch name> or refs/pull/<number>/merge\n      --succeed-on-no-caches --all   Return exit code 0 if no caches found. Must be used in conjunction with --all\n  \n",
    exit_code=1,
  )
}

///|
pub fn parse_cache_delete(
  options : BusinessOptions,
) -> Result[CacheDeleteOptions, Output] {
  let args = options.args()
  let positionals : Array[String] = []
  let mut all = false
  let mut succeed_on_empty = false
  let mut ref_name = ""
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
      if arg.has_prefix("-a") && !arg.has_prefix("-a=") {
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
    if flag is ("--all" | "-a" | "--succeed-on-no-caches") {
      let value = match attached {
        None => true
        Some(value) =>
          match actions_boolean(value) {
            Some(value) => value
            None =>
              return Err(
                cache_delete_flag_error(
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
      if flag == "--succeed-on-no-caches" {
        succeed_on_empty = value
      } else {
        all = value
      }
      continue
    }
    guard flag is ("--ref" | "-r" | "--repo" | "-R") else {
      return Err(
        cache_delete_flag_error(
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
          return Err(cache_delete_flag_error("flag needs an argument: " + flag))
        }
        let value = args[index]
        index += 1
        value
      }
    }
    if flag is ("--ref" | "-r") {
      ref_name = value
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
  if all && !positionals.is_empty() {
    return Err(
      cache_delete_flag_error(
        "specify only one of cache id, cache key, or --all",
      ),
    )
  }
  if !all && succeed_on_empty {
    return Err(
      cache_delete_flag_error(
        "--succeed-on-no-caches must be used in conjunction with --all",
      ),
    )
  }
  if !all && positionals.is_empty() {
    return Err(
      cache_delete_flag_error(
        if ref_name.is_empty() {
          "must provide either cache id, cache key, or use --all"
        } else {
          "must provide a cache key"
        },
      ),
    )
  }
  let identifier = positionals.get(0).unwrap_or("")
  let cache_id = cache_identifier_id(identifier)
  if !ref_name.is_empty() && cache_id is Some(_) {
    return Err(cache_delete_flag_error("--ref cannot be used with cache ID"))
  }
  Ok({ identifier, cache_id, ref_name, all, succeed_on_empty, })
}
