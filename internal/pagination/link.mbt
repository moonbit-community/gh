///|
/// Read the documented MoonHub next link without following server-selected
/// origins, resources, or filters. This is a bounded policy parser, rather
/// than a general URI or RFC 8288 implementation. The pinned async/http
/// package exposes header values but has no Link parser to reuse.
pub fn next_path(
  link : String,
  origin~ : String,
  current_path~ : String,
  api_prefix? : String = "/api/v1",
) -> Result[String?, @gh.ApiError] {
  let invalid = @gh.Decode(message="invalid pagination link")
  guard link.length() <= 65536 &&
    link
    .iter()
    .all(ch => ch == '\t' || (ch.to_int() >= 32 && ch.to_int() < 127)) &&
    @gh.valid_request_path(current_path) &&
    @gh.valid_request_path(api_prefix) &&
    !api_prefix.contains_char('?') &&
    !api_prefix.has_suffix("/") else {
    return Err(invalid)
  }
  let origin = match @gh.normalize_origin(origin) {
    Ok(origin) => origin
    Err(_) => return Err(invalid)
  }
  let mut cursor = skip_space(link, 0)
  let mut next : String? = None
  while cursor < link.length() {
    guard link[cursor] == '<' else { return Err(invalid) }
    let start = cursor + 1
    cursor = start
    while cursor < link.length() && link[cursor] != '>' {
      guard link[cursor].to_int() > 32 &&
        link[cursor] != '<' &&
        link[cursor] != '"' else {
        return Err(invalid)
      }
      cursor += 1
    }
    guard cursor < link.length() && cursor > start else { return Err(invalid) }
    let target = link[start:cursor].to_owned()
    cursor = skip_space(link, cursor + 1)
    let mut is_next = false
    let mut has_rel = false
    let mut has_anchor = false
    while cursor < link.length() && link[cursor] == ';' {
      cursor = skip_space(link, cursor + 1)
      let name_start = cursor
      while cursor < link.length() && is_token(link.get_char(cursor).unwrap()) {
        cursor += 1
      }
      guard cursor > name_start else { return Err(invalid) }
      let name = link[name_start:cursor].to_owned().to_lower()
      cursor = skip_space(link, cursor)
      let value = if cursor < link.length() && link[cursor] == '=' {
        match parameter_value(link, skip_space(link, cursor + 1)) {
          Some((value, end)) => {
            cursor = skip_space(link, end)
            Some(value)
          }
          None => return Err(invalid)
        }
      } else {
        None
      }
      if name == "rel" {
        guard !has_rel else { return Err(invalid) }
        has_rel = true
        guard value is Some(value) && !value.is_empty() else {
          return Err(invalid)
        }
        is_next = value
          .to_lower()
          .replace_all(old="\t", new=" ")
          .split(" ")
          .any(relation => relation == "next")
      } else if name == "anchor" {
        has_anchor = true
      }
    }
    if is_next {
      guard next is None && !has_anchor else { return Err(invalid) }
      next = Some(target)
    }
    if cursor < link.length() {
      guard link[cursor] == ',' else { return Err(invalid) }
      cursor = skip_space(link, cursor + 1)
      guard cursor < link.length() else { return Err(invalid) }
    }
  }
  match next {
    None => Ok(None)
    Some(target) => {
      let current = match page_query(current_path) {
        Some(value) => value
        None => return Err(invalid)
      }
      let resolved = match
        resolve_target(target, origin, current.0, api_prefix) {
        Some(path) => path
        None => return Err(invalid)
      }
      let following = match page_query(resolved) {
        Some(value) => value
        None => return Err(invalid)
      }
      guard following.0 == current.0 &&
        following.1 == current.1 + 1 &&
        following.2 == current.2 else {
        return Err(invalid)
      }
      Ok(Some("\{current.0}?page=\{following.1}&per_page=\{following.2}"))
    }
  }
}

///|
fn skip_space(value : String, start : Int) -> Int {
  let mut cursor = start
  while cursor < value.length() &&
        (value[cursor] == ' ' || value[cursor] == '\t') {
    cursor += 1
  }
  cursor
}

///|
fn is_token(ch : Char) -> Bool {
  ch is ('a'..='z' | 'A'..='Z' | '0'..='9') ||
  "!#$%&'*+-.^_`|~".contains_char(ch)
}

///|
fn parameter_value(link : String, start : Int) -> (String, Int)? {
  guard start < link.length() else { return None }
  let mut cursor = start
  if link[cursor] == '"' {
    cursor += 1
    let value = StringBuilder()
    while cursor < link.length() && link[cursor] != '"' {
      if link[cursor] == '\\' {
        cursor += 1
        guard cursor < link.length() else { return None }
      }
      value.write_char(link.get_char(cursor).unwrap())
      cursor += 1
    }
    guard cursor < link.length() else { return None }
    Some((value.to_string(), cursor + 1))
  } else {
    while cursor < link.length() && is_token(link.get_char(cursor).unwrap()) {
      cursor += 1
    }
    if cursor == start {
      None
    } else {
      Some((link[start:cursor].to_owned(), cursor))
    }
  }
}

///|
fn resolve_target(
  target : String,
  origin : String,
  current_route : String,
  api_prefix : String,
) -> String? {
  let path = if target.has_prefix("?") {
    current_route + target
  } else if target.has_prefix("/") {
    guard !target.has_prefix("//") else { return None }
    guard target.strip_prefix(api_prefix) is Some(path) else { return None }
    path.to_owned()
  } else if target.split_once("://") is Some((scheme, rest)) {
    guard rest.split_once("/") is Some((authority, path)) else { return None }
    let target_origin = "\{scheme}://\{authority}"
    guard @gh.normalize_origin(target_origin) is Ok(actual) && actual == origin else {
      return None
    }
    let path = "/" + path.to_owned()
    guard path.strip_prefix(api_prefix) is Some(path) else { return None }
    path.to_owned()
  } else {
    guard current_route.rev_split_once("/") is Some((directory, _)) else {
      return None
    }
    directory.to_owned() + "/" + target
  }
  if @gh.valid_request_path(path) {
    Some(path)
  } else {
    None
  }
}

///|
fn page_query(path : String) -> (String, Int, Int)? {
  guard path.split_once("?") is Some((route, query)) else { return None }
  let mut page : Int? = None
  let mut per_page : Int? = None
  for field in query.split("&") {
    guard field.split_once("=") is Some((key, value)) else { return None }
    guard !value.is_empty() &&
      value.length() <= 7 &&
      !value.has_prefix("0") &&
      value.iter().all(ch => ch.is_ascii_digit()) else {
      return None
    }
    let number = @string.parse_int(value) catch { _ => return None }
    if key == "page" && page is None && number <= 1000000 {
      page = Some(number)
    } else if key == "per_page" && per_page is None && number <= 100 {
      per_page = Some(number)
    } else {
      return None
    }
  }
  match (page, per_page) {
    (Some(page), Some(per_page)) => Some((route.to_owned(), page, per_page))
    _ => None
  }
}
