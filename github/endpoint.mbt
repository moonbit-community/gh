///|
priv struct Endpoint {
  origin : String
  authority : String
  path : String
}

///|
/// Parse the destination before credentials are attached. Plain HTTP is only
/// accepted for exact loopback names, never for hostname prefixes.
fn parse_endpoint(value : String, query~ : Bool = false) -> Endpoint? {
  guard value.length() <= 16384 &&
    value.iter().all(ch => ch.to_int() > 32 && ch.to_int() < 127) &&
    !value.contains_char('\\') &&
    !value.contains_char('#') else {
    return None
  }
  let (scheme, rest) = match value.split_once("://") {
    Some((scheme, rest)) if scheme == "https" || scheme == "http" =>
      (scheme.to_owned(), rest.to_owned())
    _ => return None
  }
  let (authority, path) = match rest.split_once("/") {
    Some((authority, path)) => (authority.to_owned(), "/" + path.to_owned())
    None => (rest, "/")
  }
  let (host, port) = match authority.split_once(":") {
    Some((host, port)) => (host.to_owned().to_lower(), Some(port.to_owned()))
    None => (authority.to_lower(), None)
  }
  guard !host.is_empty() && host.length() <= 253 else { return None }
  for label in host.split(".") {
    guard !label.is_empty() &&
      label.length() <= 63 &&
      !label.has_prefix("-") &&
      !label.has_suffix("-") &&
      label.iter().all(ch => ch is ('a'..<='z' | '0'..<='9' | '-')) else {
      return None
    }
  }
  guard scheme == "https" || host == "localhost" || host == "127.0.0.1" else {
    return None
  }
  let suffix = match port {
    None => ""
    Some(port) => {
      guard !port.is_empty() &&
        port.length() <= 5 &&
        port.iter().all(ch => ch is ('0'..<='9')) else {
        return None
      }
      let number = @string.parse_int(port) catch { _ => return None }
      guard number > 0 && number <= 65535 else { return None }
      if (scheme == "https" && number == 443) ||
        (scheme == "http" && number == 80) {
        ""
      } else {
        ":\{number}"
      }
    }
  }
  guard valid_path(path) && (query || !path.contains_char('?')) else {
    return None
  }
  let authority = host + suffix
  Some({ origin: scheme + "://" + authority, authority, path, })
}

///|
fn normalized_endpoint(value : String) -> String? {
  parse_endpoint(value).map(endpoint => {
    let suffix = if endpoint.path == "/" { "" } else { endpoint.path }
    endpoint.origin + suffix
  })
}
