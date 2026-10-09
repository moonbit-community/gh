///|
/// Canonical credential scope. Accept HTTPS origins and explicit loopback HTTP
/// for local development. Paths, userinfo and implicit hosts are not accepted.
pub fn normalize_origin(base_url : String) -> Result[String, ApiError] {
  let invalid = InvalidRequest(
    message="expected an HTTPS origin or loopback HTTP origin",
  )
  let value = base_url.to_lower()
  let (scheme, rest) = match value.split_once("://") {
    Some((scheme, rest)) if scheme == "https" || scheme == "http" =>
      (scheme.to_owned(), rest.to_owned())
    _ => return Err(invalid)
  }
  let authority = rest.strip_suffix("/").map_or(rest, x => x.to_owned())
  guard !authority.is_empty() &&
    authority.length() <= 300 &&
    authority
    .iter()
    .all(ch => ch is ('a'..='z' | '0'..='9') || ".-:".contains_char(ch)) else {
    return Err(invalid)
  }
  // The pinned native HTTP library does not resolve bracketed IPv6 literals;
  // keep the shared contract within its tested DNS/IPv4 subset.
  let (host, port) = match authority.split_once(":") {
    Some((host, port)) => (host.to_owned(), Some(port.to_owned()))
    None => (authority, None)
  }
  guard !host.is_empty() && host.length() <= 253 else { return Err(invalid) }
  for label in host.split(".") {
    guard !label.is_empty() &&
      label.length() <= 63 &&
      !label.has_prefix("-") &&
      !label.has_suffix("-") &&
      label.iter().all(ch => ch is ('a'..='z' | '0'..='9' | '-')) else {
      return Err(invalid)
    }
  }
  guard scheme == "https" || host == "localhost" || host == "127.0.0.1" else {
    return Err(invalid)
  }
  let port_suffix = match port {
    None => ""
    Some(text) => {
      guard !text.is_empty() &&
        text.length() <= 5 &&
        text.iter().all(ch => ch.is_ascii_digit()) else {
        return Err(invalid)
      }
      let number = @string.parse_int(text) catch { _ => return Err(invalid) }
      guard number > 0 && number <= 65535 else { return Err(invalid) }
      if (scheme == "https" && number == 443) ||
        (scheme == "http" && number == 80) {
        ""
      } else {
        ":\{number}"
      }
    }
  }
  Ok(scheme + "://" + host + port_suffix)
}

///|
/// Accept a single origin-relative API path and opaque query. Reject path
/// traversal and encoded separators so adapters cannot reinterpret the origin
/// or escape the API prefix. Query values do not participate in path routing.
pub fn valid_request_path(path : String) -> Bool {
  guard path.has_prefix("/") &&
    !path.has_prefix("//") &&
    !path.contains_char('#') &&
    !path.contains_char('\\') &&
    path.iter().all(ch => ch.to_int() > 32 && ch.to_int() < 127) else {
    return false
  }
  let route = path.split_once("?").map_or(path, pair => pair.0.to_owned())
  let lowered = route.to_lower()
  if lowered.contains("%2f") ||
    lowered.contains("%5c") ||
    lowered.contains("%25") ||
    lowered.contains("%00") ||
    lowered.contains("%0d") ||
    lowered.contains("%0a") {
    return false
  }
  let decoded_dots = lowered.replace_all(old="%2e", new=".")
  for segment in decoded_dots.split("/") {
    if segment == "." || segment == ".." {
      return false
    }
  }
  // Ensure every percent escape is complete; raw non-ASCII must be encoded.
  let mut i = 0
  while i < path.length() {
    if path[i] == '%' {
      guard i + 2 < path.length() else { return false }
      for j in (i + 1)..<=(i + 2) {
        let c = path[j]
        guard c is ('0'..='9' | 'a'..='f' | 'A'..='F') else { return false }
      }
      i += 3
    } else {
      i += 1
    }
  }
  true
}
