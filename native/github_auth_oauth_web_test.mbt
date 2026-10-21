///|
fn web_oauth_test_query(value : String) -> Map[String, String] raise {
  let fields : Map[String, String] = Map([])
  for field in value.split("&") {
    guard field.find("=") is Some(separator) else {
      fail("missing fixture query value")
    }
    let name = @percent.decode(field[:separator])
    let value = @percent.decode(field[separator + 1:])
    assert_false(fields.contains(name))
    fields[name] = value
  }
  fields
}

///|
fn web_oauth_test_prompt_query(
  prompt : @native.OAuthWebPrompt,
) -> Map[String, String] raise {
  let url = prompt.authorization_uri()
  guard url.find("?") is Some(question) else {
    fail("missing authorization query")
  }
  web_oauth_test_query(url[question + 1:].to_owned())
}

///|
fn web_oauth_test_transport(
  body~ : Bytes = b"{\"access_token\":\"fixture-access-token\",\"token_type\":\"bearer\"}",
  status~ : Int32 = 200,
) -> @gh.RawTransport {
  @gh.RawTransport::new(origin="https://github.com", send=request => {
    assert_eq(request.verb(), "POST")
    assert_eq(request.path(), "/login/oauth/access_token")
    assert_false(
      request
      .headers()
      .any(pair => pair.0.equal_ignore_ascii_case("authorization")),
    )
    @gh.RawHttpResponse::new(status~, body~)
  })
}

///|
async test "OAuth web binds S256 PKCE state redirect and token exchange without exposing credentials" {
  let mut prompt_fields : Map[String, String] = Map([])
  let mut redirect = ""
  let mut calls = 0
  let transport = @gh.RawTransport::new(origin="https://github.com", send=request => {
    calls += 1
    assert_eq(request.verb(), "POST")
    assert_eq(request.path(), "/login/oauth/access_token")
    assert_eq(request.headers(), [
      ("Accept", "application/json"),
      ("Content-Type", "application/x-www-form-urlencoded"),
    ])
    let form = web_oauth_test_query(@utf8.decode(request.body().unwrap()))
    assert_eq(form.length(), 5)
    assert_eq(form.get("client_id"), Some("fixture-app"))
    assert_eq(form.get("client_secret"), Some("fixture-secret"))
    assert_eq(form.get("code"), Some("fixture-code"))
    assert_eq(form.get("redirect_uri"), Some(redirect))
    let verifier = form.get("code_verifier").unwrap()
    assert_eq(verifier.length(), 43)
    assert_true(
      verifier
      .iter()
      .all(ch => {
        (ch >= 'a' && ch <= 'z') ||
        (ch >= 'A' && ch <= 'Z') ||
        (ch >= '0' && ch <= '9') ||
        ch == '-' ||
        ch == '_'
      }),
    )
    let challenge = @base64.encode(
        Bytes::from_array(@crypto.sha256(@utf8.encode(verifier))[:]),
        padding=false,
      )
      .replace_all(old="+", new="-")
      .replace_all(old="/", new="_")
    assert_eq(prompt_fields.get("code_challenge"), Some(challenge))
    assert_false(prompt_fields.values().any(value => value == verifier))
    @gh.RawHttpResponse::new(
      status=200,
      body=b"{\"access_token\":\"fixture-access-token\",\"token_type\":\"bearer\"}",
    )
  })
  let adapter = @native.web_oauth_adapter(
    client_id="fixture-app",
    client_secret="fixture-secret",
    transport~,
    present=prompt => {
      assert_true(
        prompt
        .authorization_uri()
        .has_prefix("https://github.com/login/oauth/authorize?"),
      )
      assert_false(prompt.authorization_uri().contains("fixture-secret"))
      assert_true(prompt.redirect_uri().has_prefix("http://127.0.0.1:"))
      assert_true(prompt.redirect_uri().has_suffix("/callback"))
      assert_eq(prompt.timeout_ms(), 600000)
      redirect = prompt.redirect_uri()
      prompt_fields = web_oauth_test_prompt_query(prompt)
      assert_eq(prompt_fields.length(), 6)
      assert_eq(prompt_fields.get("client_id"), Some("fixture-app"))
      assert_eq(prompt_fields.get("scope"), Some("repo read:org gist"))
      assert_eq(prompt_fields.get("redirect_uri"), Some(redirect))
      assert_eq(prompt_fields.get("code_challenge_method"), Some("S256"))
      assert_eq(prompt_fields.get("state").unwrap().length(), 43)
      true
    },
    callback=prompt => {
      let state = web_oauth_test_prompt_query(prompt).get("state").unwrap()
      Ok("/callback?code=fixture-code&state=" + state)
    },
  )
  assert_eq(
    adapter.authorize_async("github.com", "repo,read:org,gist"),
    Ok("fixture-access-token"),
  )
  assert_eq(calls, 1)
}

///|
async test "OAuth web rejects missing mismatched duplicated and malformed callback state before token exchange" {
  for
    scenario in [
      "mismatch", "missing", "duplicate", "encoded-duplicate", "fragment", "absolute",
      "wrong-path", "bad-percent", "both-code-error", "empty-code",
    ] {
    let transport = @gh.RawTransport::new(origin="https://github.com", send=_ => {
      fail("invalid callback must not exchange a token")
    })
    let adapter = @native.web_oauth_adapter(
      client_id="fixture-app",
      client_secret="fixture-secret",
      transport~,
      present=_ => true,
      callback=prompt => {
        let state = web_oauth_test_prompt_query(prompt).get("state").unwrap()
        Ok(
          match scenario {
            "mismatch" => "/callback?code=fixture-code&state=wrong-state"
            "missing" => "/callback?code=fixture-code"
            "duplicate" =>
              "/callback?code=fixture-code&state=" + state + "&state=" + state
            "encoded-duplicate" =>
              "/callback?code=fixture-code&state=" + state + "&%73tate=" + state
            "fragment" =>
              "/callback?code=fixture-code&state=" + state + "#fragment"
            "absolute" =>
              "https://evil.example/callback?code=fixture-code&state=" + state
            "wrong-path" => "/other?code=fixture-code&state=" + state
            "bad-percent" => "/callback?code=%ZZ&state=" + state
            "both-code-error" =>
              "/callback?code=fixture-code&error=access_denied&state=" + state
            _ => "/callback?code=&state=" + state
          },
        )
      },
    )
    assert_eq(
      adapter.authorize_async("github.com", "repo"),
      Err(@native.OAuthError::Failed),
    )
  }
}

///|
async test "OAuth web distinguishes user denial presentation cancellation and callback cancellation" {
  for scenario in ["denied", "presentation", "callback"] {
    let transport = @gh.RawTransport::new(origin="https://github.com", send=_ => {
      fail("cancelled authorization must not exchange a token")
    })
    let adapter = @native.web_oauth_adapter(
      client_id="fixture-app",
      client_secret="fixture-secret",
      transport~,
      present=_ => scenario != "presentation",
      callback=prompt => {
        if scenario == "callback" {
          Err(@native.OAuthError::Cancelled)
        } else {
          let state = web_oauth_test_prompt_query(prompt).get("state").unwrap()
          Ok("/callback?error=access_denied&state=" + state)
        }
      },
    )
    assert_eq(
      adapter.authorize_async("github.com", "repo"),
      Err(
        if scenario == "denied" {
          @native.OAuthError::Denied
        } else {
          @native.OAuthError::Cancelled
        },
      ),
    )
  }
}

///|
async test "OAuth web rejects invalid configuration and transport origin before browser presentation" {
  for
    (client_id, client_secret, origin, timeout_ms) in [
      ("", "fixture-secret", "https://github.com", 1000),
      ("fixture-app", "", "https://github.com", 1000),
      ("fixture-app", "secret\nvalue", "https://github.com", 1000),
      ("fixture-app", "fixture-secret", "http://github.com", 1000),
      ("fixture-app", "fixture-secret", "https://evil.example", 1000),
      ("fixture-app", "fixture-secret", "https://github.com", 0),
      ("fixture-app", "fixture-secret", "https://github.com", 600001),
    ] {
    let transport = @gh.RawTransport::new(origin~, send=_ => {
      fail("invalid configuration sent HTTP")
    })
    let adapter = @native.web_oauth_adapter(
      client_id~,
      client_secret~,
      transport~,
      timeout_ms~,
      present=_ => fail("invalid configuration opened browser"),
    )
    assert_eq(
      adapter.authorize_async("github.com", "repo"),
      Err(@native.OAuthError::InvalidConfiguration),
    )
  }
}

///|
async test "OAuth web rejects malformed scopes before browser presentation" {
  for
    scopes in [
      "repo\nbad", "repo&evil=1", "repo?bad", "repo%20gist", "repo\tgist",
    ] {
    let adapter = @native.web_oauth_adapter(
      client_id="fixture-app",
      client_secret="fixture-secret",
      transport=@gh.RawTransport::new(origin="https://github.com", send=_ => {
        fail("malformed scope sent HTTP")
      }),
      present=_ => fail("malformed scope opened browser"),
    )
    assert_eq(
      adapter.authorize_async("github.com", scopes),
      Err(@native.OAuthError::InvalidConfiguration),
    )
  }
}

///|
async test "OAuth web fails closed on expiring invalid denied and redirected token responses" {
  for
    (status, body, expected) in [
      (
        200,
        b"{\"access_token\":\"fixture-token\",\"token_type\":\"bearer\",\"expires_in\":28800}",
        @native.OAuthError::ExpiringTokenUnsupported,
      ),
      (
        200,
        b"{\"access_token\":\"fixture-token\",\"token_type\":\"bearer\",\"refresh_token\":\"fixture-refresh\"}",
        @native.OAuthError::ExpiringTokenUnsupported,
      ),
      (
        200,
        b"{\"access_token\":\"fixture-token\",\"token_type\":\"mac\"}",
        @native.OAuthError::Failed,
      ),
      (
        200,
        b"{\"access_token\":\"\",\"token_type\":\"bearer\"}",
        @native.OAuthError::Failed,
      ),
      (
        200,
        b"{\"error\":\"access_denied\",\"error_description\":\"fixture-sensitive-detail\"}",
        @native.OAuthError::Denied,
      ),
      (
        200,
        b"{\"error\":\"bad_verification_code\"}",
        @native.OAuthError::Failed,
      ),
      (302, b"", @native.OAuthError::Failed),
      (500, b"fixture-sensitive-error", @native.OAuthError::Failed),
    ] {
    let adapter = @native.web_oauth_adapter(
      client_id="fixture-app",
      client_secret="fixture-secret",
      transport=web_oauth_test_transport(status~, body~),
      present=_ => true,
      callback=prompt => {
        let state = web_oauth_test_prompt_query(prompt).get("state").unwrap()
        Ok("/callback?code=fixture-code&state=" + state)
      },
    )
    assert_eq(adapter.authorize_async("github.com", "repo"), Err(expected))
  }
}

///|
async test "OAuth web bounds callback waiting and propagates external cancellation" {
  let transport = @gh.RawTransport::new(origin="https://github.com", send=_ => {
    fail("timeout sent HTTP")
  })
  let expired = @native.web_oauth_adapter(
    client_id="fixture-app",
    client_secret="fixture-secret",
    transport~,
    timeout_ms=10,
    present=_ => true,
    callback=_ => {
      @async.sleep(1000)
      Err(@native.OAuthError::Failed)
    },
  )
  assert_eq(
    expired.authorize_async("github.com", "repo"),
    Err(@native.OAuthError::Expired),
  )
  let interrupted = @native.web_oauth_adapter(
    client_id="fixture-app",
    client_secret="fixture-secret",
    transport~,
    present=_ => true,
    callback=_ => {
      @async.sleep(1000)
      Err(@native.OAuthError::Failed)
    },
  )
  try
    @async.with_timeout(10, () => {
      interrupted.authorize_async("github.com", "repo")
    })
  catch {
    @async.TimeoutError => ()
    _ => fail("unexpected interruption")
  } noraise {
    _ => fail("external cancellation must propagate")
  }
}

///|
async test "OAuth web real loopback callback exchanges token and closes its listener" {
  let mut redirect = ""
  let mut callback_result = ""
  @async.with_task_group() <| group => {
    let adapter = @native.web_oauth_adapter(
      client_id="fixture-app",
      client_secret="fixture-secret",
      transport=web_oauth_test_transport(),
      timeout_ms=2000,
      present=prompt => {
        redirect = prompt.redirect_uri()
        let state = web_oauth_test_prompt_query(prompt).get("state").unwrap()
        group.spawn_bg() <| () => {
          let (response, body) = @http.get(
            redirect + "?code=fixture-code&state=" + state,
          )
          assert_eq(response.code, 200)
          assert_eq(response.headers.get("Cache-Control"), Some("no-store"))
          callback_result = body.text()
        }
        true
      },
    )
    assert_eq(
      adapter.authorize_async("github.com", "repo"),
      Ok("fixture-access-token"),
    )
  }
  assert_true(callback_result.contains("Authorization response received"))
  assert_false(callback_result.contains("fixture-code"))
  assert_false(callback_result.contains("fixture-access-token"))
  let authority = redirect
    .strip_prefix("http://")
    .unwrap()
    .strip_suffix("/callback")
    .unwrap()
    .to_owned()
  let closed = try {
    let connection = @socket.Tcp::connect(@socket.Addr::parse(authority))
    connection.close()
    false
  } catch {
    _ => true
  }
  assert_true(closed)
}

///|
async test "OAuth web loopback rejects wrong host method and oversized headers without token exchange" {
  for scenario in ["host", "method", "large"] {
    @async.with_task_group() <| group => {
      let transport = @gh.RawTransport::new(origin="https://github.com", send=_ => {
        fail("invalid loopback sent HTTP")
      })
      let adapter = @native.web_oauth_adapter(
        client_id="fixture-app",
        client_secret="fixture-secret",
        transport~,
        timeout_ms=2000,
        present=prompt => {
          let authority = prompt
            .redirect_uri()
            .strip_prefix("http://")
            .unwrap()
            .strip_suffix("/callback")
            .unwrap()
            .to_owned()
          let state = web_oauth_test_prompt_query(prompt).get("state").unwrap()
          group.spawn_bg() <| () => {
            let connection = @socket.Tcp::connect(
              @socket.Addr::parse(authority),
            )
            defer connection.close()
            let request_verb = if scenario == "method" { "POST" } else { "GET" }
            let host = if scenario == "host" {
              "evil.example"
            } else {
              authority
            }
            let head = request_verb +
              " /callback?code=fixture-code&state=" +
              state +
              " HTTP/1.1\r\nHost: " +
              host +
              "\r\n"
            if scenario == "large" {
              connection.write(head + "X-Large: " + "x".repeat(8192))
            } else {
              connection.write(head + "\r\n")
            }
            let response = connection.read_all().text() catch {
                error => if scenario == "large" { "" } else { raise error }
              }
            // Closing with unread oversized bytes may reset the TCP peer.
            assert_true(
              response.has_prefix("HTTP/1.1 400") ||
              (scenario == "large" && response.is_empty()),
            )
          }
          true
        },
      )
      assert_eq(
        adapter.authorize_async("github.com", "repo"),
        Err(@native.OAuthError::Failed),
      )
    }
  }
}
