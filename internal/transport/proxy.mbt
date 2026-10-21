///|
// MoonbitHTTP exposes explicit proxy configuration, but neither it nor
// moonbitlang/async selects environment proxies. Reuse its URI parser and
// async/http's CONNECT transport; keep only environment policy here.
fn first_proxy_variable(
  get : (String) -> String?,
  names : Array[String],
) -> String? {
  for name in names {
    if get(name) is Some(value) && !value.is_empty() {
      return Some(value)
    }
  }
  None
}

///|
fn proxy_bypassed(host : String, port : Int32, exclusions : String) -> Bool {
  if host == "localhost" ||
    (host.has_prefix("127.") && @http_types.IpAddress::parse(host) is Ok(_)) {
    return true
  }
  for entry in exclusions.split(",") {
    let entry = entry.trim().to_owned().to_lower()
    if entry == "*" {
      return true
    }
    if entry.is_empty() {
      continue
    }
    let (domain, required_port) = match entry.split_once(":") {
      Some((domain, port)) => (domain.to_owned(), Some(port.to_owned()))
      None => (entry, None)
    }
    if required_port is Some(value) && value != port.to_string() {
      continue
    }
    let suffix_only = domain.has_prefix(".") || domain.has_prefix("*.")
    let domain = domain.strip_prefix("*.").map_or(domain, x => x.to_owned())
    let domain = domain.strip_prefix(".").map_or(domain, x => x.to_owned())
    if !domain.is_empty() &&
      ((!suffix_only && host == domain) || host.has_suffix("." + domain)) {
      return true
    }
  }
  false
}

///|
fn proxy_from_environment(
  origin : String,
  get : (String) -> String?,
) -> String? raise {
  let target = match @http_types.Uri::parse(origin) {
    Ok(value) => value
    Err(_) => raise InvalidConfiguration
  }
  guard target.authority is Some(authority) else { raise InvalidConfiguration }
  let secure = target.scheme == Some("https")
  if proxy_bypassed(
      authority.host.to_lower(),
      authority.port.unwrap_or(if secure { 443 } else { 80 }),
      first_proxy_variable(get, ["NO_PROXY", "no_proxy"]).unwrap_or(""),
    ) {
    return None
  }
  let selected = first_proxy_variable(
    get,
    if secure {
      ["HTTPS_PROXY", "https_proxy", "ALL_PROXY", "all_proxy"]
    } else {
      ["HTTP_PROXY", "http_proxy", "ALL_PROXY", "all_proxy"]
    },
  )
  guard selected is Some(selected) else { return None }
  let uri = match @http_types.Uri::parse(selected) {
    Ok(uri) => uri
    Err(_) => raise InvalidConfiguration
  }
  // This release supports unauthenticated HTTP(S) proxies. Reject
  // other forms explicitly rather than silently sending traffic directly.
  guard uri.scheme is Some("http" | "https") &&
    uri.authority is Some(endpoint) &&
    endpoint.userinfo is None &&
    !endpoint.ip_literal &&
    (uri.path.is_empty() || uri.path == "/") &&
    uri.query is None &&
    uri.fragment is None else {
    raise InvalidConfiguration
  }
  Some(uri.scheme.unwrap() + "://" + endpoint.value)
}

///|
async fn connect_via_proxy(origin : String, proxy : String?) -> @http.Client {
  match proxy {
    None => @http.Client(origin)
    Some(address) if origin.has_prefix("http://") => @http.Client(address)
    Some(address) => {
      let tunnel = @http.Client(address)
      // Client takes ownership of the proxy and closes it on connect failure.
      @http.Client(origin, proxy=tunnel)
    }
  }
}

///|
fn proxy_request_target(
  origin : String,
  path : String,
  proxy : String?,
) -> String {
  if proxy is Some(_) && origin.has_prefix("http://") {
    origin + path
  } else {
    path
  }
}
