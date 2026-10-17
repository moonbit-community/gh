///|
// Deliberately bounded YAML mapping representation. Credentials may pass
// through this tree while a per-host setting is updated: never derive Debug.
priv enum LocalYaml {
  Scalar(String)
  Mapping(Map[String, LocalYaml])
}

///|
priv suberror LocalConfigError

///|
fn local_scalar(source : String) -> String raise LocalConfigError {
  let value = source.trim().to_owned()
  if value.has_prefix("\"") {
    let parsed = @json.parse(value) catch { _ => raise LocalConfigError }
    guard parsed is String(value) else { raise LocalConfigError }
    return value
  }
  if value.has_prefix("'") {
    guard value.length() >= 2 && value.has_suffix("'") else {
      raise LocalConfigError
    }
    let inner = value[1:value.length() - 1].to_owned()
    guard !inner.replace_all(old="''", new="").contains("'") else {
      raise LocalConfigError
    }
    return inner.replace_all(old="''", new="'")
  }
  guard !value.has_prefix("&") &&
    !value.has_prefix("*") &&
    !value.has_prefix("!") &&
    !value.has_prefix("[") &&
    !value.has_prefix("{") &&
    !value.has_prefix("|") &&
    !value.has_prefix(">") else {
    raise LocalConfigError
  }
  value.split(" #").next().unwrap_or("").trim().to_owned()
}

///|
fn local_pair(line : String) -> (String, String) raise LocalConfigError {
  let mut quote : Char? = None
  let mut escaped = false
  for index in 0..<line.length() {
    guard line.get_char(index) is Some(ch) else { continue }
    if escaped {
      escaped = false
      continue
    }
    if quote is Some('\"') && ch == '\\' {
      escaped = true
      continue
    }
    if ch == '\"' || ch.to_int() == 39 {
      match quote {
        None => quote = Some(ch)
        Some(open) if open == ch => quote = None
        _ => ()
      }
    }
    if ch == ':' &&
      quote is None &&
      (index + 1 == line.length() || line[index + 1] == ' ') {
      let key = local_scalar(line[:index].to_owned())
      guard !key.is_empty() else { raise LocalConfigError }
      return (key, line[index + 1:].trim().to_owned())
    }
  }
  raise LocalConfigError
}

///|
fn local_yaml_parse(
  source : String,
) -> Map[String, LocalYaml] raise LocalConfigError {
  guard source.length() <= 1048576 else { raise LocalConfigError }
  let root : Map[String, LocalYaml] = Map([])
  let scopes : Array[(Int32, Map[String, LocalYaml])] = [(-1, root)]
  let lines = source.split("\n").collect()
  let mut index = 0
  while index < lines.length() {
    let line = lines[index].strip_suffix("\r").unwrap_or(lines[index])
    index += 1
    if line.trim().is_empty() ||
      line.trim().has_prefix("#") ||
      line.trim() == "---" ||
      line.trim() == "..." {
      continue
    }
    guard !line.contains_char('\t') else { raise LocalConfigError }
    let mut indent = 0
    while indent < line.length() && line[indent] == ' ' {
      indent += 1
    }
    while scopes.length() > 1 && scopes[scopes.length() - 1].0 >= indent {
      ignore(scopes.pop())
    }
    let parent = scopes[scopes.length() - 1].1
    guard indent == 0 || scopes.length() > 1 else { raise LocalConfigError }
    let (key, value) = local_pair(line[indent:].to_owned())
    guard !parent.contains(key) else { raise LocalConfigError }
    if value == "{}" {
      parent[key] = Mapping(Map([]))
    } else if value.is_empty() {
      let mut nested = false
      for lookahead in index..<lines.length() {
        let next = lines[lookahead]
        if next.trim().is_empty() || next.trim().has_prefix("#") {
          continue
        }
        let mut spaces = 0
        while spaces < next.length() && next[spaces] == ' ' {
          spaces += 1
        }
        nested = spaces > indent
        break
      }
      if nested {
        let child : Map[String, LocalYaml] = Map([])
        parent[key] = Mapping(child)
        scopes.push((indent, child))
      } else {
        parent[key] = Scalar("")
      }
    } else if value is ("|" | "|-" | "|+" | ">" | ">-" | ">+") {
      let content : Array[String] = []
      let mut content_indent : Int32? = None
      while index < lines.length() {
        let next = lines[index]
        let mut spaces = 0
        while spaces < next.length() && next[spaces] == ' ' {
          spaces += 1
        }
        if !next.trim().is_empty() && spaces <= indent {
          break
        }
        if !next.trim().is_empty() && content_indent is None {
          content_indent = Some(spaces)
        }
        let start = content_indent.unwrap_or(spaces)
        guard next.trim().is_empty() || spaces >= start else {
          raise LocalConfigError
        }
        content.push(
          if next.trim().is_empty() {
            ""
          } else {
            next[start:].to_owned()
          },
        )
        index += 1
      }
      let separator = if value.has_prefix(">") { " " } else { "\n" }
      let text = content.join(separator)
      parent[key] = Scalar(
        if value.has_suffix("-") {
          text.trim_end(chars="\n").to_owned()
        } else {
          text.trim_end(chars="\n").to_owned() + "\n"
        },
      )
    } else {
      parent[key] = Scalar(local_scalar(value))
    }
  }
  root
}

///|
fn local_yaml_quote(value : String) -> String {
  Json(value).stringify()
}

///|
fn local_yaml_render(
  values : Map[String, LocalYaml],
  indent : String,
) -> String {
  let output = StringBuilder()
  let keys = values.keys().collect()
  keys.sort()
  for key in keys {
    output.write_string(indent + local_yaml_quote(key) + ":")
    match values[key] {
      Scalar(value) => output.write_string(" " + local_yaml_quote(value) + "\n")
      Mapping(child) if child.is_empty() => output.write_string(" {}\n")
      Mapping(child) =>
        output.write_string("\n" + local_yaml_render(child, indent + "  "))
    }
  }
  output.to_string()
}

///|
async fn local_read_yaml(path : String) -> Map[String, LocalYaml] {
  if !@fs.exists(path) {
    return Map([])
  }
  guard @fs.kind(path) == @fs.Regular && @fs.file_size(path) <= 1048576L else {
    raise LocalConfigError
  }
  local_yaml_parse(@fs.read_file(path).text())
}

///|
async fn local_write_yaml(
  directory : String,
  name : String,
  values : Map[String, LocalYaml],
) -> Unit {
  if !@fs.exists(directory) {
    @fs.mkdir(directory, recursive=true, permission=0o700)
  }
  guard @env.rand(16) is Some(random) else { raise LocalConfigError }
  let suffix = random
    .to_array()
    .map(value => value.to_int().to_string(radix=16))
    .join("")
  let temporary = directory + "/." + name + "." + suffix
  @fs.write_file(
    temporary,
    local_yaml_render(values, ""),
    create_mode=@fs.CreateNew,
    permission=0o600,
    sync=@fs.Full,
  )
  errdefer (@fs.remove(temporary) catch { _ => () })
  @fs.rename(temporary, directory + "/" + name, replace=true)
}

///|
fn local_config_dir(explicit : String?) -> String raise LocalConfigError {
  let value = match explicit {
    Some(value) => value
    None =>
      match config_hosts_path() {
        Some(path) => path.strip_suffix("/hosts.yml").unwrap().to_owned()
        None => raise LocalConfigError
      }
  }
  guard !value.is_empty() &&
    value.length() <= 4096 &&
    !value.iter().any(ch => ch.to_int() < 32 || ch.to_int() == 127) else {
    raise LocalConfigError
  }
  value
}

///|
fn local_error(message : String, code~ : Int32 = 1) -> @github_cli.Output {
  @github_cli.Output::new(stdout="", stderr=message + "\n", exit_code=code)
}

///|
fn local_get(values : Map[String, LocalYaml], key : String) -> String? {
  match values.get(key) {
    Some(Scalar(value)) => Some(value)
    Some(Mapping(child)) if child.is_empty() => Some("")
    _ => None
  }
}

///|
let local_options : Array[(String, String)] = [
  ("api_host", ""),
  ("git_protocol", "https"),
  ("editor", ""),
  ("prompt", "enabled"),
  ("prefer_editor_prompt", "disabled"),
  ("pager", ""),
  ("http_unix_socket", ""),
  ("browser", ""),
  ("clipboard", "enabled"),
  ("color_labels", "disabled"),
  ("accessible_colors", "disabled"),
  ("accessible_prompter", "disabled"),
  ("spinner", "enabled"),
  ("telemetry", "enabled"),
]

///|
fn local_default(key : String) -> String? {
  for (name, value) in local_options {
    if name == key {
      return Some(value)
    }
  }
  None
}

///|
fn local_config_value(
  root : Map[String, LocalYaml],
  hosts : Map[String, LocalYaml],
  host : String?,
  key : String,
) -> String? {
  if host is Some(host) &&
    hosts.get(host) is Some(Mapping(values)) &&
    local_get(values, key) is Some(value) {
    return Some(value)
  }
  match local_get(root, key) {
    Some(value) => Some(value)
    None => local_default(key)
  }
}

///|
/// Execute the local `config get/list/set` surface; argv excludes `config`.
/// The optional directory is a test/embedding boundary, never a CLI flag.
pub async fn github_config_command(
  args : Array[String],
  config_dir? : String,
) -> @github_cli.Output {
  github_config_local(args, local_config_dir(config_dir)) catch {
    err if @async.is_being_cancelled() => raise err
    _ => local_error("failed to read or write GitHub configuration")
  }
}

///|
async fn github_config_local(
  args : Array[String],
  directory : String,
) -> @github_cli.Output {
  guard args.get(0) is Some(command) else {
    return local_error("a config subcommand is required")
  }
  let operands : Array[String] = []
  let mut host : String? = None
  let mut index = 1
  let mut literal = false
  while index < args.length() {
    let arg = args[index]
    index += 1
    if literal {
      operands.push(arg)
    } else if arg == "--" {
      literal = true
    } else if arg is ("--host" | "-h") {
      guard args.get(index) is Some(value) else {
        return local_error("flag needs an argument: " + arg)
      }
      host = Some(value)
      index += 1
    } else if arg.has_prefix("--host=") {
      host = Some(arg[7:].to_owned())
    } else if arg.has_prefix("-") {
      return local_error("unknown flag: " + arg)
    } else {
      operands.push(arg)
    }
  }
  let needed = match command {
    "get" => 1
    "set" => 2
    "list" => 0
    _ =>
      return local_error(
        "unknown command \"" + command + "\" for \"gh config\"",
      )
  }
  guard operands.length() == needed else {
    return local_error(
      "accepts " +
      needed.to_string() +
      " arg(s), received " +
      operands.length().to_string(),
    )
  }
  if host is Some(value) &&
    @github_auth.resolve(@github_auth.Environment::new(gh_host=value)) is Err(_) {
    return local_error("invalid hostname")
  }
  let root = local_read_yaml(directory + "/config.yml")
  let hosts = if host is Some(_) {
    local_read_yaml(directory + "/hosts.yml")
  } else {
    Map([])
  }
  if command == "list" {
    let out = StringBuilder()
    for (key, _) in local_options {
      out.write_string(
        key +
        "=" +
        local_config_value(root, hosts, host, key).unwrap_or("") +
        "\n",
      )
    }
    return @github_cli.success(stdout=out.to_string())
  }
  let key = operands[0]
  if key is ("oauth_token" | "users" | "hosts") {
    return local_error("credential fields are not exposed by config")
  }
  if command == "get" {
    return match local_config_value(root, hosts, host, key) {
      Some(value) =>
        @github_cli.success(
          stdout=if value.is_empty() { "" } else { value + "\n" },
        )
      None => local_error("could not find key \"" + key + "\"")
    }
  }
  let value = operands[1]
  let valid = match key {
    "git_protocol" => Some(["https", "ssh"])
    "prompt"
    | "prefer_editor_prompt"
    | "clipboard"
    | "color_labels"
    | "accessible_colors"
    | "accessible_prompter"
    | "spinner" => Some(["enabled", "disabled"])
    "telemetry" => Some(["enabled", "disabled", "log"])
    _ => None
  }
  if valid is Some(values) && !values.contains(value) {
    return local_error(
      "failed to set \"" +
      key +
      "\" to \"" +
      value +
      "\": valid values are " +
      values.map(value => "'" + value + "'").join(", "),
    )
  }
  if key.is_empty() || key.contains_char('\n') {
    return local_error("invalid configuration key")
  }
  if host is Some(host) {
    let values = match hosts.get(host) {
      Some(Mapping(values)) => values
      _ => Map([])
    }
    values[key] = Scalar(value)
    hosts[host] = Mapping(values)
    local_write_yaml(directory, "hosts.yml", hosts)
  } else {
    root[key] = Scalar(value)
    local_write_yaml(directory, "config.yml", root)
  }
  @github_cli.success(
    stdout="",
    stderr=if local_default(key) is None {
      "! warning: '" + key + "' is not a known configuration key\n"
    } else {
      ""
    },
  )
}

///|
let local_commands : Array[String] = [
  "alias", "api", "auth", "browse", "cache", "completion", "config", "discussion",
  "gist", "gpg-key", "issue", "label", "org", "pr", "project", "release", "repo",
  "ruleset", "run", "search", "secret", "ssh-key", "status", "variable", "workflow",
  "help", "version", "codespace", "copilot", "agent-task", "attestation", "extension",
  "skills", "send-telemetry", "preview", "accessibility", "licenses",
]

///|
fn local_aliases(
  root : Map[String, LocalYaml],
) -> Map[String, LocalYaml] raise LocalConfigError {
  match root.get("aliases") {
    None => {
      let values : Map[String, LocalYaml] = { "co": Scalar("pr checkout") }
      root["aliases"] = Mapping(values)
      values
    }
    Some(Mapping(values)) => values
    _ => raise LocalConfigError
  }
}

///|
fn local_alias_quote(value : String) -> String {
  if value.is_empty() {
    return "\"\""
  }
  if value.contains_char('\n') ||
    value.contains_char('\r') ||
    value.contains_char('\t') {
    return Json(value).stringify()
  }
  if value.trim() != value ||
    value.has_prefix("!") ||
    value.has_prefix("&") ||
    value.has_prefix("*") ||
    value.has_prefix("{") ||
    value.has_prefix("[") ||
    value.has_prefix("#") ||
    value.has_prefix("'") ||
    value.has_prefix("\"") ||
    value.has_prefix("@") ||
    value.has_prefix("`") ||
    value.has_prefix("|") ||
    value.has_prefix(">") ||
    value.contains(": ") ||
    value.contains(" #") {
    return "'" + value.replace_all(old="'", new="''") + "'"
  }
  value
}

///|
fn local_alias_validate(
  name : String,
  expansion : String,
  aliases : Map[String, LocalYaml],
) -> String? {
  if name.is_empty() ||
    name.iter().any(ch => ch.to_int() < 32 || ch.to_int() == 127) {
    return Some("invalid alias name")
  }
  if local_commands.contains(name) {
    return Some("already a gh command or extension")
  }
  if expansion.has_prefix("!") {
    return None
  }
  let first = expansion.trim().split(" ").next().unwrap_or("").to_owned()
  if local_commands.contains(first) || aliases.contains(first) {
    None
  } else {
    Some("expansion does not correspond to a gh command, extension, or alias")
  }
}

///|
async fn local_stdin_text(input : String?) -> String {
  match input {
    Some(text) => {
      guard text.length() <= 1048576 else { raise LocalConfigError }
      text
    }
    None => {
      let bytes = Buffer()
      while @io.Reader::read_some(@stdio.stdin, max_len=65536) is Some(chunk) {
        guard bytes.length() + chunk.length() <= 1048576 else {
          raise LocalConfigError
        }
        bytes.write_bytes(chunk)
      }
      @utf8.decode(bytes.to_bytes())
    }
  }
}

///|
/// Execute local alias persistence operations; argv excludes `alias`. Shell
/// aliases are saved as text only; this function never executes expansions.
pub async fn github_alias_command(
  args : Array[String],
  config_dir? : String,
  input? : String,
) -> @github_cli.Output {
  github_alias_local(args, local_config_dir(config_dir), input) catch {
    err if @async.is_being_cancelled() => raise err
    _ => local_error("failed to read or write GitHub aliases")
  }
}

///|
async fn github_alias_local(
  args : Array[String],
  directory : String,
  input : String?,
) -> @github_cli.Output {
  guard args.get(0) is Some(command) else {
    return local_error("an alias subcommand is required")
  }
  let operands : Array[String] = []
  let mut clobber = false
  let mut shell = false
  let mut all = false
  let mut literal = false
  for arg in args[1:] {
    if literal {
      operands.push(arg)
    } else if arg == "--" {
      literal = true
    } else if arg == "--clobber" && command is ("set" | "import") {
      clobber = true
    } else if arg is ("--shell" | "-s") && command == "set" {
      shell = true
    } else if arg == "--all" && command == "delete" {
      all = true
    } else if arg.has_prefix("-") && arg != "-" {
      return local_error("unknown flag: " + arg)
    } else {
      operands.push(arg)
    }
  }
  let needed = match command {
    "list" => 0
    "set" => 2
    "import" => 1
    "delete" => if all { 0 } else { 1 }
    _ =>
      return local_error("unknown command \"" + command + "\" for \"gh alias\"")
  }
  guard operands.length() == needed else {
    return local_error(
      "accepts " +
      needed.to_string() +
      " arg(s), received " +
      operands.length().to_string(),
    )
  }
  let root = local_read_yaml(directory + "/config.yml")
  let aliases = local_aliases(root)
  if command == "list" {
    let keys = aliases.keys().collect()
    keys.sort()
    let output = StringBuilder()
    for key in keys {
      guard local_get(aliases, key) is Some(value) else {
        raise LocalConfigError
      }
      output.write_string(
        local_alias_quote(key) + ": " + local_alias_quote(value) + "\n",
      )
    }
    return @github_cli.success(stdout=output.to_string())
  }
  if command == "delete" {
    if all {
      aliases.clear()
    } else {
      guard aliases.contains(operands[0]) else {
        return local_error("no such alias " + operands[0])
      }
      aliases.remove(operands[0])
    }
  } else if command == "set" {
    let name = operands[0]
    if aliases.contains(name) && !clobber {
      return local_error(
        "X Could not create alias " +
        name +
        ": name already taken, use the --clobber flag to overwrite it",
      )
    }
    let expansion = if operands[1] == "-" {
      local_stdin_text(input).trim_end(chars="\r\n").to_owned()
    } else {
      operands[1]
    }
    let expansion = if shell && !expansion.has_prefix("!") {
      "!" + expansion
    } else {
      expansion
    }
    if local_alias_validate(name, expansion, aliases) is Some(error) {
      return local_error("X Could not create alias " + name + ": " + error)
    }
    aliases[name] = Scalar(expansion)
  } else {
    let imported = if operands[0] == "-" {
      local_yaml_parse(local_stdin_text(input))
    } else {
      guard @fs.exists(operands[0]) else {
        return local_error("unable to read aliases file")
      }
      local_read_yaml(operands[0])
    }
    // Validate the complete input before changing the persisted map.
    let updates : Array[(String, String)] = []
    for (name, _) in imported {
      guard local_get(imported, name) is Some(expansion) else {
        raise LocalConfigError
      }
      if aliases.contains(name) && !clobber {
        continue
      }
      if local_alias_validate(name, expansion, aliases) is Some(error) {
        return local_error("X Could not create alias " + name + ": " + error)
      }
      updates.push((name, expansion))
    }
    for (name, expansion) in updates {
      aliases[name] = Scalar(expansion)
    }
  }
  local_write_yaml(directory, "config.yml", root)
  @github_cli.success(stdout="")
}
