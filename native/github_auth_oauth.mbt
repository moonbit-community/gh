///|
/// The only device-flow values a host may display. Device codes and tokens
/// never enter this callback, process arguments, or trace observers.
pub struct OAuthDevicePrompt {
  priv user_code : String
  priv verification_uri : String
  priv expires_in : Int32
}

///|
pub fn OAuthDevicePrompt::user_code(self : OAuthDevicePrompt) -> String {
  self.user_code
}

///|
pub fn OAuthDevicePrompt::verification_uri(self : OAuthDevicePrompt) -> String {
  self.verification_uri
}

///|
pub fn OAuthDevicePrompt::expires_in(self : OAuthDevicePrompt) -> Int32 {
  self.expires_in
}

///|
fn oauth_form_value(value : String) -> String {
  let out = StringBuilder()
  let hex = "0123456789ABCDEF"
  for byte in @utf8.encode(value) {
    let n = byte.to_int()
    if (n >= 65 && n <= 90) ||
      (n >= 97 && n <= 122) ||
      (n >= 48 && n <= 57) ||
      n == 45 ||
      n == 46 ||
      n == 95 ||
      n == 126 {
      out.write_char(n.unsafe_to_char())
    } else {
      out.write_char('%')
      out.write_char(hex[n / 16].to_int().unsafe_to_char())
      out.write_char(hex[n % 16].to_int().unsafe_to_char())
    }
  }
  out.to_string()
}

///|
fn oauth_form(fields : Array[(String, String)]) -> Bytes {
  @utf8.encode(
    fields
    .map(pair => oauth_form_value(pair.0) + "=" + oauth_form_value(pair.1))
    .join("&"),
  )
}

///|
fn oauth_safe_text(value : String, limit : Int32) -> Bool {
  !value.is_empty() &&
  value.length() <= limit &&
  value.iter().all(ch => ch.to_int() >= 33 && ch.to_int() <= 126)
}

///|
async fn oauth_post(
  transport : @gh.RawTransport,
  path : String,
  fields : Array[(String, String)],
) -> Result[Json, OAuthError] {
  let response = transport.send(
    @gh.RawRequest::new(verb="POST", path~, body=oauth_form(fields), headers=[
      ("Accept", "application/json"),
      ("Content-Type", "application/x-www-form-urlencoded"),
    ]),
  ) catch {
    err if @async.is_being_cancelled() => raise err
    _ => return Err(OAuthError::Failed)
  }
  guard response.status() == 200 && response.body().length() <= 65536 else {
    return Err(OAuthError::Failed)
  }
  let body = @json.parse(@utf8.decode(response.body())) catch {
    _ => return Err(OAuthError::Failed)
  }
  Ok(body)
}

///|
/// GitHub OAuth App device authorization. The configured App must enable
/// device flow. Only its public client ID is needed; no client secret is used.
/// The transport is scoped to the authorization host, follows no redirects,
/// and bypasses API tracing because OAuth bodies contain credentials.
/// `present` returns false to cancel before polling. Inject timing and HTTP
/// for deterministic tests; defaults use bounded native HTTPS and real time.
pub fn device_oauth_adapter(
  client_id~ : String,
  present~ : async (OAuthDevicePrompt) -> Bool,
  transport? : @gh.RawTransport,
  wait~ : async (Int32) -> Unit = delay => @async.sleep(delay),
  now~ : () -> UInt64 = () => @env.now(),
) -> OAuthAdapter {
  OAuthAdapter::new_async(authorize=(host, scopes) => {
    guard oauth_safe_text(client_id, 256) else {
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
    let initial = match
      oauth_post(transport, "/login/device/code", [
        ("client_id", client_id),
        ("scope", scope_names.join(" ")),
      ]) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    let (device_code, user_code, verification_uri, expires_in, interval) = match
      initial {
      {
        "device_code": String(device),
        "user_code": String(user),
        "verification_uri": String(uri),
        "expires_in": Number(expires, ..),
        ..
      } => {
        let interval = match initial {
          { "interval": Number(value, ..), .. } => value
          { "interval": _, .. } => return Err(OAuthError::Failed)
          _ => 5.0
        }
        guard oauth_safe_text(device, 4096) &&
          oauth_safe_text(user, 64) &&
          uri == origin + "/login/device" &&
          expires >= 1 &&
          expires <= 3600 &&
          expires.to_int().to_double() == expires &&
          interval >= 1 &&
          interval <= 60 &&
          interval.to_int().to_double() == interval else {
          return Err(OAuthError::Failed)
        }
        (device, user, uri, expires.to_int(), interval.to_int())
      }
      _ => return Err(OAuthError::Failed)
    }
    let started = now()
    let lifetime = (expires_in * 1000).to_uint64()
    let prompt = { user_code, verification_uri, expires_in, }
    try
      @async.with_timeout(expires_in * 1000) <| () => {
        guard present(prompt) else { return Err(OAuthError::Cancelled) }
        let mut delay = interval * 1000
        let mut waited = 0
        while waited < expires_in * 1000 {
          let current = now()
          if current < started ||
            current - started >= lifetime ||
            delay >= expires_in * 1000 - waited {
            return Err(OAuthError::Expired)
          }
          wait(delay)
          waited += delay
          let current = now()
          if current < started || current - started >= lifetime {
            return Err(OAuthError::Expired)
          }
          let response = match
            oauth_post(transport, "/login/oauth/access_token", [
              ("client_id", client_id),
              ("device_code", device_code),
              ("grant_type", "urn:ietf:params:oauth:grant-type:device_code"),
            ]) {
            Ok(value) => value
            Err(error) => return Err(error)
          }
          match response {
            { "error": String("authorization_pending"), .. } => ()
            { "error": String("slow_down"), .. } => {
              delay += 5000
              match response {
                { "interval": Number(value, ..), .. } if value >= 1 &&
                  value <= 3600 &&
                  value.to_int().to_double() == value =>
                  if value.to_int() * 1000 > delay {
                    delay = value.to_int() * 1000
                  }
                { "interval": _, .. } => return Err(OAuthError::Failed)
                _ => ()
              }
            }
            { "error": String("access_denied"), .. } =>
              return Err(OAuthError::Denied)
            { "error": String("expired_token"), .. } =>
              return Err(OAuthError::Expired)
            { "error": _, .. } => return Err(OAuthError::Failed)
            { "expires_in": _, .. } | { "refresh_token": _, .. } =>
              return Err(OAuthError::ExpiringTokenUnsupported)
            { "access_token": String(token), "token_type": String(kind), .. } if kind.equal_ignore_ascii_case(
                "bearer",
              ) &&
              oauth_safe_text(token, 4096) => return Ok(token)
            _ => return Err(OAuthError::Failed)
          }
        }
        Err(OAuthError::Expired)
      }
    catch {
      err if @async.is_being_cancelled() => raise err
      @async.TimeoutError => Err(OAuthError::Expired)
      _ => Err(OAuthError::Failed)
    }
  })
}

///|
/// Host default uses a caller-owned OAuth App, never GitHub CLI's client ID.
fn default_oauth_adapter(args : Array[String]) -> OAuthAdapter? {
  guard @env.get_env_var("GH_OAUTH_CLIENT_ID") is Some(client_id) else {
    return None
  }
  let flow = @env.get_env_var("GH_OAUTH_FLOW").unwrap_or("device")
  let clipboard = args.contains("--clipboard") || args.contains("-c")
  if flow == "device" {
    Some(
      device_oauth_adapter(client_id~, present=prompt => {
        @stdio.stderr.write(
          "First copy your one-time code: " +
          prompt.user_code() +
          "\nOpen " +
          prompt.verification_uri() +
          " to authorize this application.\n",
        )
        if clipboard && !oauth_clipboard(prompt.user_code()) {
          @stdio.stderr.write(
            "Could not copy the code to the clipboard; copy it manually.\n",
          )
        }
        oauth_open_browser(prompt.verification_uri())
        true
      }),
    )
  } else if flow == "web" {
    guard @env.get_env_var("GH_OAUTH_CLIENT_SECRET") is Some(client_secret) else {
      return Some(
        OAuthAdapter::new(authorize=(_, _) => {
          Err(OAuthError::InvalidConfiguration)
        }),
      )
    }
    Some(
      web_oauth_adapter(client_id~, client_secret~, present=prompt => {
        @stdio.stderr.write(
          "Open " +
          prompt.authorization_uri() +
          " to authorize this application.\n",
        )
        oauth_open_browser(prompt.authorization_uri())
        true
      }),
    )
  } else {
    Some(
      OAuthAdapter::new(authorize=(_, _) => {
        Err(OAuthError::InvalidConfiguration)
      }),
    )
  }
}

///|
async fn oauth_open_browser(url : String) -> Unit {
  let configured = configured_browser(None)
  let command = if configured == "xdg-open" && @async.platform is MacOS {
    "open"
  } else if configured == "xdg-open" && @async.platform is Windows {
    "rundll32 url.dll,FileProtocolHandler"
  } else {
    configured
  }
  let opened = match split_native_command(command) {
    Ok((program, args)) => {
      args.push(url)
      match auth_host_process(program, args, b"") {
        Ok(result) => result.exit_code() == 0
        Err(_) => false
      }
    }
    Err(_) => false
  }
  if !opened {
    @stdio.stderr.write(
      "Could not open a browser; open the URL above manually.\n",
    )
  }
}

///|
async fn oauth_clipboard(code : String) -> Bool {
  let commands = match @async.platform {
    MacOS => [("pbcopy", [])]
    Windows => [("clip.exe", [])]
    _ => [("wl-copy", []), ("xclip", ["-selection", "clipboard"])]
  }
  for (program, args) in commands {
    match auth_host_process(program, args, @utf8.encode(code)) {
      Ok(result) if result.exit_code() == 0 => return true
      _ => ()
    }
  }
  false
}
