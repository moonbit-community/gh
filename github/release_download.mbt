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
  self.release_download_with(path, request => {
    self.send_attempts(
      request,
      Disabled,
      operation_id="release-download",
      operation_name="release.download",
    )
  })
}

///|
/// Buffered and streaming downloads share the same endpoint and redirect
/// policy. No callback can select an origin before this policy approves it.
async fn Client::release_download_with(
  self : Client,
  path : String,
  send : async (Request) -> Result[RawResponse, GitHubError],
) -> Result[RawResponse, GitHubError] {
  self.download_with(path, actions=false, send)
}

///|
async fn Client::download_with(
  self : Client,
  path : String,
  actions~ : Bool,
  send : async (Request) -> Result[RawResponse, GitHubError],
  archive~ : Bool = false,
) -> Result[RawResponse, GitHubError] {
  let segments = path.split("/").to_array()
  let valid = if actions {
    actions_download_path(segments)
  } else if archive {
    segments.length() == 6 &&
    segments[4] is ("zipball" | "tarball") &&
    !segments[5].is_empty()
  } else {
    segments.length() == 7 &&
    segments[4] == "releases" &&
    segments[5] == "assets" &&
    download_numeric_id(segments[6].to_owned())
  }
  guard !path.contains_char('?') &&
    valid &&
    segments[0].is_empty() &&
    segments[1] == "repos" &&
    !segments[2].is_empty() &&
    !segments[3].is_empty() else {
    return Err(InvalidRequest(message="invalid download API path"))
  }
  let base = match parse_endpoint(self.config.base_url) {
    Some(value) => value
    None => return Err(InvalidConfiguration(message="invalid API origin"))
  }
  let accept = if actions {
    "application/vnd.github+json"
  } else if archive {
    "application/octet-stream, application/json"
  } else {
    "application/octet-stream"
  }
  let mut request = match
    self.prepare(
      Request::new(verb="GET", path~, headers=[("Accept", accept)]),
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
    let result = send(request)
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
      (if actions {
        actions_download_origin(target.origin)
      } else if archive {
        target.origin == "https://codeload.github.com"
      } else {
        target.origin == "https://release-assets.githubusercontent.com" ||
        target.origin == "https://github-releases.githubusercontent.com"
      })
    guard same_origin || trusted_cdn else {
      return Err(InvalidRequest(message="untrusted release asset redirect"))
    }
    if !same_origin {
      credentials_removed = true
    }
    let headers = if credentials_removed {
      [("Accept", accept), ("User-Agent", self.config.user_agent)]
    } else {
      request.headers.copy()
    }
    let target_path = if archive &&
      hop == 0 &&
      target.origin == "https://codeload.github.com" {
      let prefix = "/" +
        segments[2].to_owned() +
        "/" +
        segments[3].to_owned() +
        "/legacy."
      target.path
      .strip_prefix(prefix)
      .map_or(target.path, rest => {
        "/" +
        segments[2].to_owned() +
        "/" +
        segments[3].to_owned() +
        "/" +
        rest.to_owned()
      })
    } else {
      target.path
    }
    request = {
      ..Request::new(verb="GET", path=target_path, headers~),
      url: target.origin + target_path,
    }
  }
  Err(InvalidRequest(message="too many release asset redirects"))
}

///|
fn download_numeric_id(value : String) -> Bool {
  !value.is_empty() && value.iter().all(ch => ch is ('0'..<='9'))
}

///|
fn actions_download_path(parts : Array[StringView]) -> Bool {
  if parts.length() < 8 || parts[4] != "actions" {
    return false
  }
  match parts {
    [_, _, _, _, _, "artifacts", id, "zip"] =>
      download_numeric_id(id.to_owned())
    [_, _, _, _, _, "runs" | "jobs", id, "logs"] =>
      download_numeric_id(id.to_owned())
    [_, _, _, _, _, "runs", id, "attempts", attempt, "logs"] =>
      download_numeric_id(id.to_owned()) &&
      download_numeric_id(attempt.to_owned())
    _ => false
  }
}

///|
/// Actions' documented storage domains. This only permits a credential-free
/// redirect after an authenticated API download; it never authorizes an API
/// request or an arbitrary initial URL.
pub fn actions_download_origin(origin : String) -> Bool {
  guard parse_endpoint(origin) is Some(endpoint) &&
    endpoint.origin == origin &&
    endpoint.path == "/" &&
    origin.has_prefix("https://") &&
    !endpoint.authority.contains_char(':') else {
    return false
  }
  endpoint.authority.has_suffix(".blob.core.windows.net") ||
  endpoint.authority.has_suffix(".actions.githubusercontent.com")
}
