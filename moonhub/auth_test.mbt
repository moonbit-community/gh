///|
test "token precedence is explicit then environment then matching config origin" {
  let config =
    #|{"version":1,"hosts":{"https://moonhub.example":"config-token"}}
  match
    @moonhub.resolve_token(
      base_url="https://moonhub.example/",
      explicit="explicit-token",
      environment="environment-token",
      config_json=config,
    ) {
    Ok(Some(token)) => {
      assert_eq(token.authorization(), "Bearer explicit-token")
      assert_true(token.source() is @moonhub.Explicit)
      assert_eq(token.origin(), "https://moonhub.example")
    }
    _ => fail("explicit credential was not selected")
  }
  match
    @moonhub.resolve_token(
      base_url="https://moonhub.example",
      environment="environment-token",
      config_json=config,
    ) {
    Ok(Some(token)) => {
      assert_eq(token.authorization(), "Bearer environment-token")
      assert_true(token.source() is @moonhub.Environment)
    }
    _ => fail("environment credential was not selected")
  }
  match
    @moonhub.resolve_token(
      base_url="https://moonhub.example",
      config_json=config,
    ) {
    Ok(Some(token)) => {
      assert_eq(token.authorization(), "Bearer config-token")
      assert_true(token.source() is @moonhub.Config)
    }
    _ => fail("config credential was not selected")
  }
}

///|
test "invalid higher precedence values fail closed without leaking secrets" {
  assert_true(
    @moonhub.resolve_token(
      base_url="https://moonhub.example",
      explicit="",
      environment="valid-token",
    )
    is Err(@gh.InvalidRequest(message="invalid explicit MoonHub token")),
  )
  assert_true(
    @moonhub.resolve_token(
      base_url="https://moonhub.example",
      environment="secret\r\nAuthorization: injected",
      config_json=(
        #|{"version":1,"hosts":{"https://moonhub.example":"valid-token"}}
      ),
    )
    is Err(@gh.InvalidRequest(message="invalid MOONHUB_TOKEN")),
  )
  // Lower-priority malformed data is neither parsed nor diagnosed.
  assert_true(
    @moonhub.resolve_token(
      base_url="https://moonhub.example",
      explicit="valid-token",
      environment="",
      config_json="broken secret config",
    )
    is Ok(Some(_)),
  )
}

///|
test "config credentials are scoped to the complete normalized origin" {
  let config =
    #|{"version":1,"hosts":{"https://moonhub.example":"main-token","https://moonhub.example:8443":"other-port-token"}}
  assert_true(
    @moonhub.resolve_token(
      base_url="https://different.example",
      config_json=config,
    )
    is Ok(None),
  )
  assert_true(
    @moonhub.resolve_token(base_url="https://moonhub.example") is Ok(None),
  )
  match
    @moonhub.resolve_token(
      base_url="https://MOONHUB.EXAMPLE:443/",
      config_json=config,
    ) {
    Ok(Some(token)) => {
      assert_eq(token.authorization(), "Bearer main-token")
      assert_eq(token.origin(), "https://moonhub.example")
    }
    _ => fail("normalized origin did not match")
  }
  match
    @moonhub.resolve_token(
      base_url="https://moonhub.example:8443",
      config_json=config,
    ) {
    Ok(Some(token)) =>
      assert_eq(token.authorization(), "Bearer other-port-token")
    _ => fail("port-specific origin did not match")
  }
  assert_true(
    @moonhub.resolve_token(
      base_url="http://localhost",
      config_json=(
        #|{"version":1,"hosts":{"https://localhost":"tls-only-token"}}
      ),
    )
    is Ok(None),
  )
}

///|
test "malformed config and noncanonical origins produce fixed diagnostics" {
  assert_true(
    @moonhub.resolve_token(
      base_url="https://moonhub.example",
      config_json="secret-not-json",
    )
    is Err(@gh.InvalidRequest(message="invalid MoonHub config JSON")),
  )
  for
    config in [
      (
        #|{"version":2,"hosts":{}}
      ),
      (
        #|{"version":1,"hosts":[]}
      ),
      (
        #|{"hosts":{}}
      ),
    ] {
    assert_true(
      @moonhub.resolve_token(
        base_url="https://moonhub.example",
        config_json=config,
      )
      is Err(@gh.InvalidRequest(message="invalid MoonHub config schema")),
    )
  }
  assert_true(
    @moonhub.resolve_token(
      base_url="https://moonhub.example",
      config_json=(
        #|{"version":1,"hosts":{"https://MOONHUB.EXAMPLE":"secret-token"}}
      ),
    )
    is Err(@gh.InvalidRequest(message="invalid MoonHub config origin")),
  )
  assert_true(
    @moonhub.resolve_token(
      base_url="https://moonhub.example",
      config_json=(
        #|{"version":1,"hosts":{"https://moonhub.example":"secret with spaces"}}
      ),
    )
    is Err(@gh.InvalidRequest(message="invalid MoonHub config token")),
  )
}

///|
test "bearer token syntax rejects injection whitespace unicode and misplaced padding" {
  for
    token in [
      "", " token", "token ", "a\nb", "a\tb", "a\u{0}b", "令牌", "=", "a=b",
    ] {
    assert_true(
      @moonhub.resolve_token(base_url="https://moonhub.example", explicit=token)
      is Err(@gh.InvalidRequest(message="invalid explicit MoonHub token")),
    )
  }
  assert_true(
    @moonhub.resolve_token(
      base_url="https://moonhub.example",
      explicit="Az09-._~+/==",
    )
    is Ok(Some(_)),
  )
}
