///|
/// The selected credential source; it contains no credential material.
pub(all) enum TokenSource {
  Explicit
  Environment
  Config
}

///|
/// A validated bearer credential scoped to one normalized server origin.
/// The value deliberately has no Debug, Show, or ToJson implementation.
struct Token {
  value : String
  source : TokenSource
  origin : String
}

///|
/// Obtain a sensitive header value for transport injection only.
pub fn Token::authorization(self : Token) -> String {
  "Bearer " + self.value
}

///|
pub fn Token::source(self : Token) -> TokenSource {
  self.source
}

///|
pub fn Token::origin(self : Token) -> String {
  self.origin
}

///|
fn valid_token(value : String) -> Bool {
  if value.length() == 0 || value.length() > 4096 {
    return false
  }
  let mut padding = false
  let mut content = false
  for ch in value {
    match ch {
      '=' => {
        if !content {
          return false
        }
        padding = true
      }
      'a'..='z' | 'A'..='Z' | '0'..='9' | '-' | '.' | '_' | '~' | '+' | '/' => {
        if padding {
          return false
        }
        content = true
      }
      _ => return false
    }
  }
  true
}

///|
fn token_from_value(
  value : String,
  source : TokenSource,
  origin : String,
) -> Result[Token?, @gh.ApiError] {
  if !valid_token(value) {
    let message = match source {
      Explicit => "invalid explicit MoonHub token"
      Environment => "invalid MOONHUB_TOKEN"
      Config => "invalid MoonHub config token"
    }
    return Err(@gh.InvalidRequest(message~))
  }
  Ok(Some({ value, source, origin, }))
}

///|
fn config_token(
  source : String,
  origin : String,
) -> Result[Token?, @gh.ApiError] {
  if source.length() > 65536 {
    return Err(@gh.InvalidRequest(message="MoonHub config exceeds 64 KiB"))
  }
  let config = @wire_json.parse(source) catch {
    _ => return Err(@gh.InvalidRequest(message="invalid MoonHub config JSON"))
  }
  let hosts = match config {
    { "version": version, "hosts": Object(hosts), .. } if @wire_json.integer(
        version,
        minimum=1,
        maximum=1,
      )
      is Some(_) => hosts
    _ => return Err(@gh.InvalidRequest(message="invalid MoonHub config schema"))
  }
  // Require canonical keys so aliases cannot silently select another account.
  for host, value in hosts {
    match @gh.normalize_origin(host) {
      Ok(normalized) if normalized == host => ()
      _ =>
        return Err(@gh.InvalidRequest(message="invalid MoonHub config origin"))
    }
    match value {
      String(value) if valid_token(value) => ()
      _ =>
        return Err(@gh.InvalidRequest(message="invalid MoonHub config token"))
    }
  }
  match hosts.get(origin) {
    Some(String(value)) => token_from_value(value, Config, origin)
    _ => Ok(None)
  }
}

///|
/// Resolve explicitly supplied inputs without reading process state or files.
/// Selection order is explicit token, environment value, then config JSON.
/// An invalid selected source is an error and never falls back to another one.
///
/// Config JSON has the shape:
/// `{"version":1,"hosts":{"https://moonhub.example":"opaque-token"}}`.
///
/// ```mbt check
/// test {
///   match
///     @moonhub.resolve_token(
///       base_url="https://moonhub.example",
///       explicit="example-token",
///     ) {
///     Ok(Some(token)) => assert_true(token.source() is @moonhub.Explicit)
///     _ => fail("expected a validated credential")
///   }
/// }
/// ```
pub fn resolve_token(
  base_url~ : String,
  explicit? : String,
  environment? : String,
  config_json? : String,
) -> Result[Token?, @gh.ApiError] {
  let origin = match @gh.normalize_origin(base_url) {
    Ok(origin) => origin
    Err(error) => return Err(error)
  }
  if explicit is Some(value) {
    return token_from_value(value, Explicit, origin)
  }
  if environment is Some(value) {
    return token_from_value(value, Environment, origin)
  }
  match config_json {
    Some(source) => config_token(source, origin)
    None => Ok(None)
  }
}
