///|
/// Read a Link header and resolve its `next` URI against the current request.
/// RFC 8288 quoted parameters and relation lists are supported. A link with
/// an anchor is ignored; ambiguous next links and malformed syntax fail.
/// Cross-origin links are rejected before the caller can attach credentials.
pub fn next_link(
  link : String,
  current_url~ : String,
) -> Result[String?, GitHubError] {
  let invalid = Decode(message="invalid GitHub pagination link")
  guard parse_endpoint(current_url, query=true) is Some(current) &&
    link.length() <= 65536 &&
    link
    .iter()
    .all(ch => ch == '\t' || (ch.to_int() >= 32 && ch.to_int() < 127)) else {
    return Err(invalid)
  }
  let mut cursor = link_space(link, 0)
  let mut next : String? = None
  while cursor < link.length() {
    guard link[cursor] == '<' else { return Err(invalid) }
    let start = cursor + 1
    cursor = start
    while cursor < link.length() && link[cursor] != '>' {
      guard link[cursor] > 32 && link[cursor] != '<' && link[cursor] != '"' else {
        return Err(invalid)
      }
      cursor += 1
    }
    guard cursor < link.length() else { return Err(invalid) }
    let target = link[start:cursor].to_owned()
    cursor = link_space(link, cursor + 1)
    let mut relation_seen = false
    let mut is_next = false
    let mut anchored = false
    while cursor < link.length() && link[cursor] == ';' {
      cursor = link_space(link, cursor + 1)
      let start = cursor
      while cursor < link.length() &&
            is_token_char(link.get_char(cursor).unwrap()) {
        cursor += 1
      }
      guard cursor > start else { return Err(invalid) }
      let name = link[start:cursor].to_owned().to_lower()
      cursor = link_space(link, cursor)
      let value = if cursor < link.length() && link[cursor] == '=' {
        match link_value(link, link_space(link, cursor + 1)) {
          Some((value, end)) => {
            cursor = link_space(link, end)
            Some(value)
          }
          None => return Err(invalid)
        }
      } else {
        None
      }
      if name == "rel" && !relation_seen {
        relation_seen = true
        guard value is Some(value) && !value.is_empty() else {
          return Err(invalid)
        }
        is_next = value.split(" ").any(rel => rel == "next")
      } else if name == "anchor" {
        anchored = true
      }
    }
    if is_next && !anchored {
      guard next is None else { return Err(invalid) }
      let resolved = if target.has_prefix("https://") ||
        target.has_prefix("http://") {
        target
      } else if target.has_prefix("//") {
        return Err(invalid)
      } else if target.has_prefix("/") {
        current.origin + target
      } else if target.has_prefix("?") {
        current.origin +
        current.path.split("?").next().unwrap_or("/").to_owned() +
        target
      } else {
        let path = current.path.split("?").next().unwrap_or("/").to_owned()
        let segments = path.split("/").collect()
        let directory = segments[:segments.length() - 1]
          .map(segment => segment.to_owned())
          .join("/")
        current.origin + directory + "/" + target
      }
      guard parse_endpoint(resolved, query=true) is Some(endpoint) &&
        endpoint.origin == current.origin else {
        return Err(invalid)
      }
      next = Some(endpoint.origin + endpoint.path)
    }
    if cursor < link.length() {
      guard link[cursor] == ',' else { return Err(invalid) }
      cursor = link_space(link, cursor + 1)
      guard cursor < link.length() else { return Err(invalid) }
    }
  }
  Ok(next)
}

///|
pub fn RawResponse::next_url(
  self : RawResponse,
  current_url~ : String,
) -> Result[String?, GitHubError] {
  let links = self.headers
    .filter(pair => pair.0.equal_ignore_ascii_case("link"))
    .map(pair => pair.1)
  next_link(links.join(","), current_url~)
}

///|
fn link_space(value : String, offset : Int32) -> Int32 {
  let mut cursor = offset
  while cursor < value.length() &&
        (value[cursor] == ' ' || value[cursor] == '\t') {
    cursor += 1
  }
  cursor
}

///|
fn link_value(value : String, start : Int32) -> (String, Int32)? {
  guard start < value.length() else { return None }
  let mut cursor = start
  if value[cursor] == '"' {
    cursor += 1
    let output = StringBuilder()
    while cursor < value.length() {
      let ch = value.get_char(cursor).unwrap()
      if ch == '"' {
        return Some((output.to_string(), cursor + 1))
      }
      if ch == '\\' {
        cursor += 1
        guard cursor < value.length() else { return None }
      }
      output.write_char(value.get_char(cursor).unwrap())
      cursor += 1
    }
    None
  } else {
    while cursor < value.length() &&
          is_token_char(value.get_char(cursor).unwrap()) {
      cursor += 1
    }
    if cursor > start {
      Some((value[start:cursor].to_owned(), cursor))
    } else {
      None
    }
  }
}

///|
/// Find an explicitly named pageInfo object in a GraphQL result. An empty
/// path addresses a pageInfo object directly. No cursor is guessed when the
/// response has multiple connections.
pub fn graphql_next_cursor(
  value : Json,
  page_info_path~ : Array[String] = [],
) -> Result[String?, GitHubError] {
  let mut current = value
  for segment in page_info_path {
    match current {
      Object(fields) =>
        match fields.get(segment) {
          Some(value) => current = value
          None => return Err(Decode(message="GraphQL pageInfo path is absent"))
        }
      _ => return Err(Decode(message="GraphQL pageInfo path is not an object"))
    }
  }
  match current {
    { "hasNextPage": False, .. } => Ok(None)
    { "hasNextPage": True, "endCursor": String(cursor), .. } if !cursor.is_empty() =>
      Ok(Some(cursor))
    _ => Err(Decode(message="invalid GraphQL pageInfo"))
  }
}

///|
/// Return a copy with a new cursor; caller-owned variables are not mutated.
pub fn GraphQLRequest::with_cursor(
  self : GraphQLRequest,
  cursor : String,
  variable~ : String = "endCursor",
) -> Result[GraphQLRequest, GitHubError] {
  guard !cursor.is_empty() && !variable.is_empty() else {
    return Err(InvalidRequest(message="invalid GraphQL cursor variable"))
  }
  let fields : Map[String, Json] = Map([])
  match self.variables {
    None | Some(Null) => ()
    Some(Object(values)) =>
      for name, value in values {
        fields[name] = value
      }
    _ =>
      return Err(InvalidRequest(message="GraphQL variables must be an object"))
  }
  fields[variable] = Json::string(cursor)
  Ok({ ..self, variables: Some(Json::object(fields)), })
}
