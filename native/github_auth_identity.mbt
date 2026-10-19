///|
fn auth_scope_names(value : String) -> Array[String] {
  let result : Array[String] = []
  for word in value.replace_all(old=",", new=" ").split(" ") {
    let scope = word.trim().to_owned()
    if !scope.is_empty() && !result.contains(scope) {
      result.push(scope)
    }
  }
  result
}

///|
/// Verify account identity before persisting an OAuth or stdin credential.
/// Provider response text and credential material are never used as errors.
async fn auth_verify_identity(
  host : String,
  token : String,
  transport : @github.Transport?,
) -> Result[(String, String), @github_cli.Output] {
  let config = match
    @github_auth.resolve(
      @github_auth.Environment::new(gh_host=host),
      stored_token=token,
    ) {
    Ok(value) => value
    Err(_) => return Err(local_error("invalid GitHub token", code=4))
  }
  let transport = match transport {
    Some(value) => value
    None => auth_native_transport(config)
  }
  let client = match
    @github.Client::new(
      config=@github.ClientConfig::new(
        base_url=config.rest_base_url(),
        graphql_url=config.graphql_url(),
        token~,
      ),
      transport~,
    ) {
    Ok(value) => value
    Err(_) => return Err(local_error("invalid GitHub client configuration"))
  }
  let response = match
    client.request(@github.Request::new(verb="GET", path="/user")) {
    Ok(value) => value
    Err(failure) =>
      return Err(
        local_error(
          if failure.status() == Some(401) {
            "invalid GitHub credentials"
          } else {
            "unable to verify authorized account"
          },
          code=4,
        ),
      )
  }
  let body = match response.body_text() {
    Ok(text) => @json.parse(text) catch { _ => Json::null() }
    Err(_) => Json::null()
  }
  match body {
    { "login": String(login), .. } if !login.is_empty() &&
      login.length() <= 100 &&
      login.iter().all(ch => ch is ('a'..<='z' | 'A'..<='Z' | '0'..<='9' | '-')) &&
      !login.contains(token) =>
      Ok((login, response.header("x-oauth-scopes").unwrap_or("")))
    _ =>
      Err(
        local_error("authentication response did not contain a valid account"),
      )
  }
}
