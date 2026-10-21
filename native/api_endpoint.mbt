///|
/// Parse an explicitly supplied API URL before selecting a credential scope.
/// Transport validation still checks the complete path before sending.
fn api_absolute_endpoint(
  value : String,
) -> Result[(String, String)?, @github_cli.Output] {
  if !value.contains("://") {
    return Ok(None)
  }
  guard value.split_once("://") is Some((scheme, rest)) else {
    return Err(@github_cli.failure(message="invalid API URL"))
  }
  let mut boundary : Int32? = None
  for index in 0..<rest.length() {
    if rest[index] is ('/' | '?' | '#') {
      boundary = Some(index)
      break
    }
  }
  let (authority, suffix) = match boundary {
    Some(index) => (rest[:index].to_owned(), rest[index:].to_owned())
    None => (rest.to_owned(), "")
  }
  let origin = match
    @gh.normalize_origin(scheme.to_owned() + "://" + authority) {
    Ok(origin) => origin
    Err(_) => return Err(@github_cli.failure(message="invalid API origin"))
  }
  guard !suffix.contains("#") &&
    !suffix.contains("\\") &&
    suffix.iter().all(ch => ch.to_int() > 32 && ch.to_int() < 127) else {
    return Err(@github_cli.failure(message="invalid API URL"))
  }
  let path = if suffix.is_empty() || suffix.has_prefix("?") {
    "/" + suffix
  } else {
    suffix
  }
  Ok(Some((origin, path)))
}
