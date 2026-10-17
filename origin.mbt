///|
/// Invalid transport origin. Diagnostics never include the supplied URL.
pub(all) enum OriginError {
  InvalidOrigin
}

///|
/// Canonical credential scope. Accept HTTPS origins and explicit loopback HTTP
/// for local development. Paths, userinfo and implicit hosts are not accepted.
pub fn normalize_origin(base_url : String) -> Result[String, OriginError] {
  let invalid = OriginError::InvalidOrigin
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
    .all(ch => ch is ('a'..<='z' | '0'..<='9') || ".-:".contains_char(ch)) else {
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
      label.iter().all(ch => ch is ('a'..<='z' | '0'..<='9' | '-')) else {
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
