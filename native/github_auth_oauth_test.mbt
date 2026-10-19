///|
fn device_reply(body : String) -> @gh.RawHttpResponse {
  @gh.RawHttpResponse::new(status=200, body=@utf8.encode(body))
}

///|
fn device_initial() -> @gh.RawHttpResponse {
  device_reply(
    "{\"device_code\":\"private-device-code\",\"user_code\":\"ABCD-EFGH\",\"verification_uri\":\"https://github.com/login/device\",\"expires_in\":120,\"interval\":5}",
  )
}

///|
async test "device OAuth polls pending slow down and success without leaking credentials" {
  let calls = Ref(0)
  let clock = Ref(1000UL)
  let delays : Array[Int32] = []
  let shown : Array[String] = []
  let transport = @gh.RawTransport::new(origin="https://github.com", send=request => {
    assert_eq(request.verb(), "POST")
    assert_false(
      request
      .headers()
      .any(pair => pair.0.equal_ignore_ascii_case("Authorization")),
    )
    let body = @utf8.decode(request.body().unwrap())
    calls.val += 1
    if calls.val == 1 {
      assert_eq(request.path(), "/login/device/code")
      assert_eq(body, "client_id=fixture-app&scope=repo%20read%3Aorg%20gist")
      return device_initial()
    }
    assert_eq(request.path(), "/login/oauth/access_token")
    assert_true(body.contains("device_code=private-device-code"))
    assert_true(
      body.contains(
        "grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Adevice_code",
      ),
    )
    match calls.val {
      2 => device_reply("{\"error\":\"authorization_pending\"}")
      3 => device_reply("{\"error\":\"slow_down\",\"interval\":15}")
      _ =>
        device_reply(
          "{\"access_token\":\"private-result-token\",\"token_type\":\"bearer\"}",
        )
    }
  })
  let adapter = @native.device_oauth_adapter(
    client_id="fixture-app",
    transport~,
    present=prompt => {
      shown.push(prompt.user_code())
      shown.push(prompt.verification_uri())
      assert_eq(prompt.expires_in(), 120)
      true
    },
    wait=delay => {
      delays.push(delay)
      clock.val += delay.to_uint64()
    },
    now=() => clock.val,
  )
  assert_eq(
    adapter.authorize_async("github.com", "repo,read:org,gist"),
    Ok("private-result-token"),
  )
  assert_eq(delays, [5000, 5000, 15000])
  assert_eq(shown, ["ABCD-EFGH", "https://github.com/login/device"])
  assert_eq(calls.val, 4)
}

///|
async test "device OAuth denial expiry malformed replies are sanitized" {
  for
    (body, expected) in [
      (
        "{\"error\":\"access_denied\",\"error_description\":\"private-token\"}",
        @native.OAuthError::Denied,
      ),
      ("{\"error\":\"expired_token\"}", @native.OAuthError::Expired),
      (
        "{\"error\":\"incorrect_client_credentials\"}",
        @native.OAuthError::Failed,
      ),
      (
        "{\"access_token\":\"private-token\",\"token_type\":\"unknown\"}",
        @native.OAuthError::Failed,
      ),
      ("{\"error\":\"slow_down\",\"interval\":0}", @native.OAuthError::Failed),
      ("invalid private-token", @native.OAuthError::Failed),
      (
        "{\"access_token\":\"private-token\",\"token_type\":\"bearer\",\"expires_in\":28800}",
        @native.OAuthError::ExpiringTokenUnsupported,
      ),
      (
        "{\"access_token\":\"private-token\",\"token_type\":\"bearer\",\"refresh_token\":\"private-refresh\"}",
        @native.OAuthError::ExpiringTokenUnsupported,
      ),
    ] {
    let transport = @gh.RawTransport::new(origin="https://github.com", send=request => {
      if request.path() == "/login/device/code" {
        device_initial()
      } else {
        device_reply(body)
      }
    })
    let adapter = @native.device_oauth_adapter(
      client_id="fixture-app",
      transport~,
      present=_ => true,
      wait=_ => (),
      now=() => 1000UL,
    )
    assert_eq(adapter.authorize_async("github.com", "repo"), Err(expected))
  }
}

///|
async test "device OAuth rejects unsafe origins prompts and invalid timing" {
  for
    body in [
      "{\"device_code\":\"secret\",\"user_code\":\"CODE\",\"verification_uri\":\"https://evil.example/login/device\",\"expires_in\":60}",
      "{\"device_code\":\"secret\",\"user_code\":\"CODE\",\"verification_uri\":\"https://github.com/login/device\",\"expires_in\":60,\"interval\":0}",
      "{\"device_code\":\"secret\",\"user_code\":\"CODE\",\"verification_uri\":\"https://github.com/login/device\",\"expires_in\":0}",
    ] {
    let presented = Ref(false)
    let adapter = @native.device_oauth_adapter(
      client_id="fixture-app",
      transport=@gh.RawTransport::new(origin="https://github.com", send=_ => {
        device_reply(body)
      }),
      present=_ => {
        presented.val = true
        true
      },
      wait=_ => (),
    )
    assert_eq(
      adapter.authorize_async("github.com", "repo"),
      Err(@native.OAuthError::Failed),
    )
    assert_false(presented.val)
  }
  let adapter = @native.device_oauth_adapter(
    client_id="fixture-app",
    transport=@gh.RawTransport::new(origin="https://evil.example", send=_ => {
      fail("must not send")
    }),
    present=_ => true,
  )
  assert_eq(
    adapter.authorize_async("github.com", "repo"),
    Err(@native.OAuthError::InvalidConfiguration),
  )
}

///|
async test "device OAuth cancellation and elapsed expiry stop polling" {
  let calls = Ref(0)
  let transport = @gh.RawTransport::new(origin="https://github.com", send=_ => {
    calls.val += 1
    device_initial()
  })
  let cancelled = @native.device_oauth_adapter(
    client_id="fixture-app",
    transport~,
    present=_ => false,
  )
  assert_eq(
    cancelled.authorize_async("github.com", "repo"),
    Err(@native.OAuthError::Cancelled),
  )
  assert_eq(calls.val, 1)
  let clock = Ref(1000UL)
  let expired = @native.device_oauth_adapter(
    client_id="fixture-app",
    transport~,
    present=_ => true,
    wait=_ => clock.val += 120000UL,
    now=() => clock.val,
  )
  assert_eq(
    expired.authorize_async("github.com", "repo"),
    Err(@native.OAuthError::Expired),
  )
  assert_eq(calls.val, 2)
  let interrupt = @native.device_oauth_adapter(
    client_id="fixture-app",
    transport~,
    present=_ => true,
    wait=_ => @async.sleep(1000),
  )
  try
    @async.with_timeout(10, () => {
      interrupt.authorize_async("github.com", "repo")
    })
  catch {
    @async.TimeoutError => ()
    _ => fail("unexpected interruption")
  } noraise {
    _ => fail("cancellation must propagate")
  }
}
