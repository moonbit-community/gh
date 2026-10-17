///|
/// The source selected for a GitHub credential.  This enum never contains the
/// credential itself, so it is safe to include in diagnostics and traces.
pub(all) enum TokenSource {
  Unspecified
  GhToken
  GithubToken
  GhEnterpriseToken
  GithubEnterpriseToken
  Stored
} derive(Debug, Eq)

///|
pub extend TokenSource with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub extend TokenSource with Eq::{not_equal, equal}

///|
/// Environment values used by GitHub authentication resolution.
///
/// Keeping this as a value object makes precedence deterministic in tests and
/// lets callers load hosts.yml (or another credential store) without exposing
/// filesystem details to this package.  `from_process` only reads process
/// environment; it never writes it.
pub struct Environment {
  gh_host : String?
  priv gh_token : String?
  priv github_token : String?
  priv gh_enterprise_token : String?
  priv github_enterprise_token : String?
}

///|
/// Construct environment inputs without reading process state.
pub fn Environment::new(
  gh_host? : String,
  gh_token? : String,
  github_token? : String,
  gh_enterprise_token? : String,
  github_enterprise_token? : String,
) -> Environment {
  {
    gh_host,
    gh_token,
    github_token,
    gh_enterprise_token,
    github_enterprise_token,
  }
}

///|
/// Read the five GitHub authentication variables used by `gh`.
pub fn Environment::from_process() -> Environment {
  {
    gh_host: @env.get_env_var("GH_HOST"),
    gh_token: @env.get_env_var("GH_TOKEN"),
    github_token: @env.get_env_var("GITHUB_TOKEN"),
    gh_enterprise_token: @env.get_env_var("GH_ENTERPRISE_TOKEN"),
    github_enterprise_token: @env.get_env_var("GITHUB_ENTERPRISE_TOKEN"),
  }
}

///|
/// Select an explicit CLI host while preserving opaque environment secrets.
pub fn Environment::with_host(self : Environment, host : String) -> Environment {
  { ..self, gh_host: Some(host), }
}

///|
/// The URLs and selected credential for one GitHub host.
///
/// The token field is deliberately private and this type has no `Debug`,
/// `Show`, or `ToJson` implementation.  Call `token()` only at the transport
/// boundary where the Authorization header is created.
pub struct Config {
  host : String
  rest_base_url : String
  graphql_url : String
  priv token : String?
  token_source : TokenSource
}

///|
pub fn Config::host(self : Config) -> String {
  self.host
}

///|
pub fn Config::rest_base_url(self : Config) -> String {
  self.rest_base_url
}

///|
pub fn Config::graphql_url(self : Config) -> String {
  self.graphql_url
}

///|
/// Return the selected secret for transport injection.  Callers must not put
/// this value in logs, errors, traces, or command arguments.
pub fn Config::token(self : Config) -> String? {
  self.token
}

///|
pub fn Config::token_source(self : Config) -> TokenSource {
  self.token_source
}

///|
/// Errors intentionally carry no input text: environment variables and host
/// names can contain sensitive deployment details and must not be echoed.
pub(all) enum AuthError {
  InvalidHost
  InvalidToken
  InvalidConfig
} derive(Debug, Eq)

///|
pub extend AuthError with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub extend AuthError with Eq::{not_equal, equal}

///|
/// Resolve a GitHub host and credential using `gh`'s environment precedence.
///
/// For github.com, `GH_TOKEN` wins over `GITHUB_TOKEN`.  For an Enterprise
/// host, `GH_ENTERPRISE_TOKEN` wins over `GITHUB_ENTERPRISE_TOKEN`.  Empty
/// values are treated as unset.  A stored token can be supplied by a caller
/// after it has selected the host from hosts.yml; environment credentials
/// always take precedence over it.
pub fn resolve(
  environment : Environment,
  stored_token? : String,
) -> Result[Config, AuthError] {
  let host = match environment.gh_host {
    Some(value) if !value.is_empty() => value
    _ => "github.com"
  }
  let host = match validate_host(host) {
    Some(value) => value
    None => return Err(InvalidHost)
  }
  let enterprise = host != "github.com"
  let selected = if enterprise {
    first_non_empty([
      (environment.gh_enterprise_token, GhEnterpriseToken),
      (environment.github_enterprise_token, GithubEnterpriseToken),
      (stored_token, Stored),
    ])
  } else {
    first_non_empty([
      (environment.gh_token, GhToken),
      (environment.github_token, GithubToken),
      (stored_token, Stored),
    ])
  }
  let token = match selected {
    None => (None, Unspecified)
    Some((value, source)) if valid_token(value) => (Some(value), source)
    Some(_) => return Err(InvalidToken)
  }
  let (rest_base_url, graphql_url) = if enterprise {
    ("https://" + host + "/api/v3", "https://" + host + "/api/graphql")
  } else {
    ("https://api.github.com", "https://api.github.com/graphql")
  }
  Ok({
    host,
    rest_base_url,
    graphql_url,
    token: token.0,
    token_source: token.1,
  })
}

///|
fn first_non_empty(
  values : Array[(String?, TokenSource)],
) -> (String, TokenSource)? {
  for (maybe_value, source) in values {
    match maybe_value {
      Some(value) if !value.is_empty() => return Some((value, source))
      _ => ()
    }
  }
  None
}

///|
fn valid_token(value : String) -> Bool {
  if value.is_empty() || value.length() > 4096 {
    return false
  }
  // GitHub tokens are opaque, but values containing whitespace or controls
  // would make an Authorization header ambiguous.  Permit punctuation used by
  // classic and fine-grained tokens without imposing a token format.
  value.iter().all(ch => ch.to_int() >= 0x21 && ch.to_int() <= 0x7e)
}

///|
fn validate_host(value : String) -> String? {
  if value.is_empty() || value.length() > 253 {
    return None
  }
  if value.contains("://") ||
    value.contains_char('/') ||
    value.contains_char('?') ||
    value.contains_char('#') ||
    value.iter().any(ch => ch.to_int() <= 0x20 || ch.to_int() == 0x7f) {
    return None
  }
  // Permit DNS names and an optional numeric port.  We do not resolve DNS
  // here.  Bracketed IPv6 literals are intentionally rejected until the
  // native transport can represent them consistently.
  let (hostname, port) = match value.split_once(":") {
    Some((hostname, port)) => (hostname, Some(port))
    None => (value, None)
  }
  if hostname.is_empty() || hostname.length() > 253 {
    return None
  }
  for label in hostname.split(".") {
    if label.is_empty() ||
      label.length() > 63 ||
      label.has_prefix("-") ||
      label.has_suffix("-") ||
      !label
      .iter()
      .all(ch => ch is ('a'..<='z' | 'A'..<='Z' | '0'..<='9' | '-')) {
      return None
    }
  }
  match port {
    None => ()
    Some(port) => {
      if port.is_empty() ||
        port.length() > 5 ||
        !port.iter().all(ch => ch is ('0'..<='9')) {
        return None
      }
      let number = @string.parse_int(port) catch { _ => return None }
      if number < 1 || number > 65535 {
        return None
      }
    }
  }
  Some(value.to_lower())
}
