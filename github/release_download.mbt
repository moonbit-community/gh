///|
/// Download a release asset through its REST API path. Redirects are explicit
/// and bounded: GitHub.com may redirect to its release asset hosts, while
/// Enterprise downloads stay on the configured origin. Once a request leaves
/// the API origin, credentials are never reattached during this download.
///
/// Example: `client.download_release_asset("/repos/OWNER/REPO/releases/assets/123")`
/// returns the original asset bytes in `RawResponse::body`; the initial API
/// request is authenticated and signed CDN requests omit API credentials.
pub async fn Client::download_release_asset(
  self : Client,
  path : String,
) -> Result[RawResponse, GitHubError] {
  let segments = path.split("/").to_array()
  guard !path.contains_char('?') &&
    segments.length() == 7 &&
    segments[0].is_empty() &&
    segments[1] == "repos" &&
    !segments[2].is_empty() &&
    !segments[3].is_empty() &&
    segments[4] == "releases" &&
    segments[5] == "assets" &&
    !segments[6].is_empty() &&
    segments[6].iter().all(ch => ch is ('0'..<='9')) else {
    return Err(InvalidRequest(message="invalid release asset API path"))
  }
  let base = match parse_endpoint(self.config.base_url) {
    Some(value) => value
    None => return Err(InvalidConfiguration(message="invalid API origin"))
  }
  let mut request = match
    self.prepare(
      Request::new(verb="GET", path~, headers=[
        ("Accept", "application/octet-stream"),
      ]),
      graphql=false,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let visited : Map[String, Bool] = Map([])
  let mut credentials_removed = false
  for hop in 0..<=5 {
    guard !visited.contains(request.url) else {
      return Err(InvalidRequest(message="release asset redirect cycle"))
    }
    visited[request.url] = true
    let result = self.send_attempts(
      request,
      1,
      operation_id="release-download",
      operation_name="release.download",
    )
    let response = match result {
      Ok(response) => return Ok(response)
      Err(error) =>
        match error.response() {
          Some(response) if response.status() is (301 | 302 | 303 | 307 | 308) =>
            response
          _ => return Err(error)
        }
    }
    guard hop < 5 else {
      return Err(InvalidRequest(message="too many release asset redirects"))
    }
    let locations = response
      .headers()
      .filter(pair => pair.0.equal_ignore_ascii_case("location"))
    guard locations.length() == 1 else {
      return Err(InvalidRequest(message="invalid release asset redirect"))
    }
    let current = match parse_endpoint(request.url, query=true) {
      Some(value) => value
      None => return Err(InvalidRequest(message="invalid release asset URL"))
    }
    let location = locations[0].1
    let url = if location.has_prefix("/") && !location.has_prefix("//") {
      current.origin + location
    } else {
      location
    }
    let target = match parse_endpoint(url, query=true) {
      Some(value) => value
      None =>
        return Err(InvalidRequest(message="invalid release asset redirect"))
    }
    let same_origin = target.origin == base.origin
    let trusted_cdn = base.origin == "https://api.github.com" &&
      (
        target.origin == "https://release-assets.githubusercontent.com" ||
        target.origin == "https://github-releases.githubusercontent.com"
      )
    guard same_origin || trusted_cdn else {
      return Err(InvalidRequest(message="untrusted release asset redirect"))
    }
    if !same_origin {
      credentials_removed = true
    }
    let headers = if credentials_removed {
      [
        ("Accept", "application/octet-stream"),
        ("User-Agent", self.config.user_agent),
      ]
    } else {
      request.headers.copy()
    }
    request = {
      ..Request::new(verb="GET", path=target.path, headers~),
      url: target.origin + target.path,
    }
  }
  Err(InvalidRequest(message="too many release asset redirects"))
}
