///|
/// Browser-visible web authorization data, excluding client secret and verifier.
pub struct OAuthWebPrompt {
  priv authorization_uri : String
  priv redirect_uri : String
  priv timeout_ms : Int32
}

///|
pub fn OAuthWebPrompt::authorization_uri(self : OAuthWebPrompt) -> String {
  self.authorization_uri
}

///|
pub fn OAuthWebPrompt::redirect_uri(self : OAuthWebPrompt) -> String {
  self.redirect_uri
}

///|
pub fn OAuthWebPrompt::timeout_ms(self : OAuthWebPrompt) -> Int32 {
  self.timeout_ms
}

///|
fn oauth_web_base64url(bytes : Bytes) -> String {
  @base64.encode(bytes, padding=false)
  .replace_all(old="+", new="-")
  .replace_all(old="/", new="_")
}

///|
fn oauth_web_state_matches(actual : String, expected : String) -> Bool {
  guard actual.length() == expected.length() else { return false }
  let mut difference = 0
  for i in 0..<actual.length() {
    difference = difference | (actual[i].to_int() ^ expected[i].to_int())
  }
  difference == 0
}

///|
/// Only our exact relative callback path is accepted. Repeated parameters are
/// rejected after decoding so encoded aliases cannot bypass state validation.
fn oauth_web_callback_code(
  target : String,
  state : String,
) -> Result[String, OAuthError] {
  guard target.length() <= 8192 &&
    target.has_prefix("/callback?") &&
    !target.contains("#") &&
    target.iter().all(ch => ch.to_int() >= 33 && ch.to_int() <= 126) else {
    return Err(OAuthError::Failed)
  }
  let values : Map[String, String] = Map([])
  for field in target[10:].split("&") {
    guard field.find("=") is Some(separator) else {
      return Err(OAuthError::Failed)
    }
    let key = @percent.decode(field[:separator].replace_all(old="+", new=" ")) catch {
      _ => return Err(OAuthError::Failed)
    }
    let value = @percent.decode(
      field[separator + 1:].replace_all(old="+", new=" "),
    ) catch {
      _ => return Err(OAuthError::Failed)
    }
    guard !values.contains(key) else { return Err(OAuthError::Failed) }
    values[key] = value
  }
  guard values.get("state") is Some(actual) &&
    oauth_web_state_matches(actual, state) else {
    return Err(OAuthError::Failed)
  }
  match values.get("error") {
    Some("access_denied") if !values.contains("code") =>
      return Err(OAuthError::Denied)
    Some(_) => return Err(OAuthError::Failed)
    None => ()
  }
  match values.get("code") {
    Some(code) if oauth_safe_text(code, 4096) => Ok(code)
    _ => Err(OAuthError::Failed)
  }
}

///|
/// The general HTTP parser lacks a configurable header cap. This narrow
/// loopback callback reads at most 8 KiB and accepts no body or pipelining.
async fn oauth_web_read_target(
  connection : @socket.Tcp,
  authority : String,
) -> Result[String, OAuthError] {
  let head = @buffer.Buffer()
  while head.length() < 8192 {
    let remaining = 8192 - head.length()
    let chunk = connection.read_some(
      max_len=if remaining < 1024 { remaining } else { 1024 },
    )
    guard chunk is Some(chunk) else { return Err(OAuthError::Failed) }
    head.write_bytes(chunk)
    let bytes = head.to_bytes()
    match bytes.find(b"\r\n\r\n") {
      None => ()
      Some(end) => {
        guard end + 4 == bytes.length() else { return Err(OAuthError::Failed) }
        let source = @utf8.decode(bytes[:end]) catch {
          _ => return Err(OAuthError::Failed)
        }
        let lines = source.split("\r\n").to_array()
        guard lines.get(0) is Some(first) else {
          return Err(OAuthError::Failed)
        }
        let parts = first.split(" ").to_array()
        guard parts.length() == 3 &&
          parts[0] == "GET" &&
          parts[2] is ("HTTP/1.1" | "HTTP/1.0") else {
          return Err(OAuthError::Failed)
        }
        let mut found_host = false
        for line in lines[1:] {
          guard line.find(":") is Some(separator) else {
            return Err(OAuthError::Failed)
          }
          let name = line[:separator].to_owned()
          let value = line[separator + 1:].trim().to_owned()
          if name.equal_ignore_ascii_case("host") {
            guard !found_host && value == authority else {
              return Err(OAuthError::Failed)
            }
            found_host = true
          } else if name.equal_ignore_ascii_case("content-length") {
            guard value == "0" else { return Err(OAuthError::Failed) }
          } else if name.equal_ignore_ascii_case("transfer-encoding") {
            return Err(OAuthError::Failed)
          }
        }
        guard found_host else { return Err(OAuthError::Failed) }
        return Ok(parts[1].to_owned())
      }
    }
  }
  Err(OAuthError::Failed)
}

///|
async fn oauth_web_receive(
  server : @socket.TcpServer,
  state : String,
) -> Result[String, OAuthError] {
  let (connection, _) = server.accept()
  defer connection.close()
  let authority = "127.0.0.1:\{server.addr.port()}"
  let result = match oauth_web_read_target(connection, authority) {
    Ok(target) => oauth_web_callback_code(target, state)
    Err(error) => Err(error)
  }
  let (status, message) = match result {
    Ok(_) =>
      (
        "200 OK", "Authorization response received. You may return to the terminal.",
      )
    Err(_) =>
      (
        "400 Bad Request", "Authorization response rejected. Return to the terminal.",
      )
  }
  connection.write(
    "HTTP/1.1 " +
    status +
    "\r\nContent-Type: text/plain; charset=utf-8\r\n" +
    "Cache-Control: no-store\r\nPragma: no-cache\r\nReferrer-Policy: no-referrer\r\n" +
    "Content-Security-Policy: default-src 'none'; frame-ancestors 'none'\r\n" +
    "Connection: close\r\nContent-Length: \{message.length()}\r\n\r\n" +
    message,
  )
  result
}

///|
/// GitHub authorization-code flow with S256 PKCE and independent 256-bit state.
/// Registers a fresh 127.0.0.1 listener; the OAuth App callback must be
/// http://127.0.0.1/callback. The optional callback seam returns a relative
/// request target and uses the same state checks as the real listener.
/// The secret and verifier travel only in the unauthenticated HTTPS token body,
/// without API traces. Expiring tokens are rejected until refresh is supported.
pub fn web_oauth_adapter(
  client_id~ : String,
  client_secret~ : String,
  present~ : async (OAuthWebPrompt) -> Bool,
  transport? : @gh.RawTransport,
  callback? : async (OAuthWebPrompt) -> Result[String, OAuthError],
  timeout_ms~ : Int32 = 600000,
) -> OAuthAdapter {
  OAuthAdapter::new_async(authorize=(host, scopes) => {
    guard oauth_safe_text(client_id, 256) &&
      oauth_safe_text(client_secret, 4096) &&
      timeout_ms > 0 &&
      timeout_ms <= 600000 else {
      return Err(OAuthError::InvalidConfiguration)
    }
    let config = match
      @github_auth.resolve(@github_auth.Environment::new(gh_host=host)) {
      Ok(value) => value
      Err(_) => return Err(OAuthError::InvalidConfiguration)
    }
    let origin = "https://" + config.host()
    let transport = match transport {
      Some(value) if value.origin() == origin => value
      Some(_) => return Err(OAuthError::InvalidConfiguration)
      None =>
        @transport.native_raw_transport(
          base_url=origin,
          max_response_bytes=65536,
        ) catch {
          _ => return Err(OAuthError::Unavailable)
        }
    }
    let scope_names = auth_scope_names(scopes)
    guard scope_names.all(scope => {
      scope
      .iter()
      .all(ch => ch is ('a'..<='z' | 'A'..<='Z' | '0'..<='9' | ':' | '_' | '-'))
    }) else {
      return Err(OAuthError::InvalidConfiguration)
    }
    let state = oauth_web_base64url(@getrandom.bytes(32)) catch {
      _ => return Err(OAuthError::Unavailable)
    }
    let verifier = oauth_web_base64url(@getrandom.bytes(32)) catch {
      _ => return Err(OAuthError::Unavailable)
    }
    let challenge = oauth_web_base64url(
      Bytes::from_array(@crypto.sha256(@utf8.encode(verifier))[:]),
    )
    let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0")) catch {
      err if @async.is_being_cancelled() => raise err
      _ => return Err(OAuthError::Unavailable)
    }
    defer server.close()
    let redirect_uri = "http://127.0.0.1:\{server.addr.port()}/callback"
    let query = [
        ("client_id", client_id),
        ("redirect_uri", redirect_uri),
        ("scope", scope_names.join(" ")),
        ("state", state),
        ("code_challenge", challenge),
        ("code_challenge_method", "S256"),
      ]
      .map(pair => oauth_form_value(pair.0) + "=" + oauth_form_value(pair.1))
      .join("&")
    let prompt = {
      authorization_uri: origin + "/login/oauth/authorize?" + query,
      redirect_uri,
      timeout_ms,
    }
    try
      @async.with_timeout(timeout_ms) <| () => {
        guard present(prompt) else { return Err(OAuthError::Cancelled) }
        let code = match callback {
          Some(receive) =>
            match receive(prompt) {
              Ok(target) => oauth_web_callback_code(target, state)
              Err(error) => Err(error)
            }
          None => oauth_web_receive(server, state)
        }
        let code = match code {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        let response = match
          oauth_post(
            transport,
            "/login/oauth/access_token",
            [
              ("client_id", client_id),
              ("client_secret", client_secret),
              ("code", code),
              ("redirect_uri", redirect_uri),
              ("code_verifier", verifier),
            ],
            stage=WebExchange,
          ) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        match response {
          { "error": String("access_denied"), .. } => Err(OAuthError::Denied)
          { "error": _, .. } => {
            oauth_diagnostic(WebExchange, ProviderError)
            Err(OAuthError::Failed)
          }
          { "expires_in": _, .. } | { "refresh_token": _, .. } =>
            Err(OAuthError::ExpiringTokenUnsupported)
          { "access_token": String(token), "token_type": String(kind), .. } if kind.equal_ignore_ascii_case(
              "bearer",
            ) &&
            oauth_safe_text(token, 4096) => Ok(token)
          _ => {
            oauth_diagnostic(WebExchange, InvalidTokenResponse)
            Err(OAuthError::Failed)
          }
        }
      }
    catch {
      err if @async.is_being_cancelled() => raise err
      @async.TimeoutError => Err(OAuthError::Expired)
      _ => Err(OAuthError::Failed)
    }
  })
}
