///|
/// Parse the block-mapping hosts.yml written by gh. This is a bounded schema
/// parser, not a general YAML implementation: aliases, tags, nonempty flow
/// mappings, multiline scalars and tab indentation are rejected. Empty account
/// mappings under `users` represent credentials held in the OS keyring.
/// Standard unquoted,
/// single-quoted, and JSON-compatible double-quoted scalars are supported.
/// Returns only the selected host's credential, never another host's token.
pub fn hosts_token(
  source : String,
  host~ : String,
) -> Result[String?, AuthError] {
  guard validate_host(host) is Some(host) && source.length() <= 1048576 else {
    return Err(InvalidConfig)
  }
  let tokens : Map[String, String] = Map([])
  let users : Map[String, String] = Map([])
  let account_tokens : Map[String, String] = Map([])
  let seen : Map[String, Unit] = Map([])
  let scopes : Array[(Int32, String)] = []
  for line in source.split("\n") {
    let line = line.strip_suffix("\r").unwrap_or(line)
    let stripped = line.trim()
    if stripped.is_empty() ||
      stripped.has_prefix("#") ||
      stripped == "---" ||
      stripped == "..." {
      continue
    }
    guard !line.contains_char('\t') else { return Err(InvalidConfig) }
    let mut indent = 0
    while indent < line.length() && line[indent] == ' ' {
      indent += 1
    }
    let content = line[indent:].to_owned()
    let (key, value) = match yaml_pair(content) {
      Some(pair) => pair
      None => return Err(InvalidConfig)
    }
    while !scopes.is_empty() && scopes[scopes.length() - 1].0 >= indent {
      ignore(scopes.pop())
    }
    guard indent == 0 || !scopes.is_empty() else { return Err(InvalidConfig) }
    let path = scopes.map(pair => pair.1)
    path.push(key)
    let identity = path.join("\u{1f}")
    guard !seen.contains(identity) else { return Err(InvalidConfig) }
    seen[identity] = ()
    if indent == 0 {
      guard value.is_empty() && validate_host(key) is Some(_) else {
        return Err(InvalidConfig)
      }
    }
    if value.is_empty() {
      scopes.push((indent, key))
      continue
    }
    if value == "{}" && path.length() == 3 && path[1] == "users" {
      // Both our writer and upstream gh use empty account mappings when
      // the credential is held outside hosts.yml. Let the native resolver
      // consult its keyring instead of rejecting the account reference.
      continue
    }
    let scalar = match yaml_scalar(value) {
      Some(value) => value
      None => return Err(InvalidConfig)
    }
    if path.length() == 2 && path[1] == "oauth_token" {
      guard scalar.is_empty() || valid_token(scalar) else {
        return Err(InvalidToken)
      }
      tokens[path[0].to_lower()] = scalar
    } else if path.length() == 2 && path[1] == "user" {
      users[path[0].to_lower()] = scalar
    } else if path.length() == 4 &&
      path[1] == "users" &&
      path[3] == "oauth_token" {
      guard scalar.is_empty() || valid_token(scalar) else {
        return Err(InvalidToken)
      }
      account_tokens[path[0].to_lower() + "\u{1f}" + path[2]] = scalar
    }
  }
  if tokens.get(host) is Some(token) && !token.is_empty() {
    return Ok(Some(token))
  }
  if users.get(host) is Some(user) &&
    account_tokens.get(host + "\u{1f}" + user) is Some(token) &&
    !token.is_empty() {
    return Ok(Some(token))
  }
  Ok(None)
}

///|
/// Environment credentials bypass file parsing, just as they bypass disk and
/// keyring reads. Native callers provide file contents after their own I/O.
pub fn resolve_with_hosts(
  environment : Environment,
  source : String,
) -> Result[Config, AuthError] {
  let config = match resolve(environment) {
    Ok(config) => config
    Err(error) => return Err(error)
  }
  if config.token is Some(_) {
    return Ok(config)
  }
  let token = match hosts_token(source, host=config.host) {
    Ok(token) => token
    Err(error) => return Err(error)
  }
  resolve(environment, stored_token?=token)
}

///|
fn yaml_pair(line : String) -> (String, String)? {
  let mut quote : Char? = None
  let mut escaped = false
  for offset in 0..<line.length() {
    guard line.get_char(offset) is Some(ch) else { continue }
    if escaped {
      escaped = false
      continue
    }
    if ch == '\\' && quote is Some('"') {
      escaped = true
      continue
    }
    if ch == '"' || ch == '\'' {
      match quote {
        None => quote = Some(ch)
        Some(open) if open == ch => quote = None
        _ => ()
      }
    }
    if ch == ':' &&
      quote is None &&
      (offset + 1 == line.length() || line.get_char(offset + 1) is Some(' ')) {
      let key = yaml_scalar(line[:offset].trim().to_owned())
      guard key is Some(key) && !key.is_empty() && !key.contains_char('\u{1f}') else {
        return None
      }
      return Some((key, line[offset + 1:].trim().to_owned()))
    }
  }
  None
}

///|
fn yaml_scalar(value : String) -> String? {
  if value.has_prefix("\"") {
    let parsed = @json.parse(value) catch { _ => return None }
    return match parsed {
      String(value) => Some(value)
      _ => None
    }
  }
  if value.has_prefix("'") {
    guard value.length() >= 2 && value.has_suffix("'") else { return None }
    let inner = value[1:value.length() - 1].to_owned()
    let result = inner.replace_all(old="''", new="")
    if result.contains_char('\'') {
      return None
    }
    return Some(inner.replace_all(old="''", new="'"))
  }
  if value.has_prefix("&") ||
    value.has_prefix("*") ||
    value.has_prefix("!") ||
    value.has_prefix("[") ||
    value.has_prefix("{") ||
    value.has_prefix("|") ||
    value.has_prefix(">") {
    return None
  }
  let value = value.split(" #").next().unwrap_or("").trim().to_owned()
  if value.iter().any(ch => ch.to_int() < 32 || ch.to_int() == 127) {
    None
  } else {
    Some(value)
  }
}
