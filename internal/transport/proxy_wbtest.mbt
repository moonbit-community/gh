///|
test "environment proxy precedence and loopback bypass" {
  let values : Map[String, String] = {
    "HTTPS_PROXY": "http://proxy.example:8080/",
    "https_proxy": "http://lower.example:8081",
    "ALL_PROXY": "http://fallback.example:8082",
  }
  assert_eq(
    proxy_from_environment("https://github.com", name => values.get(name)),
    Some("http://proxy.example:8080"),
  )
  values.remove("HTTPS_PROXY")
  assert_eq(
    proxy_from_environment("https://github.com", name => values.get(name)),
    Some("http://lower.example:8081"),
  )
  values.remove("https_proxy")
  assert_eq(
    proxy_from_environment("https://github.com", name => values.get(name)),
    Some("http://fallback.example:8082"),
  )
  assert_eq(
    proxy_from_environment("http://127.0.0.1:9000", name => values.get(name)),
    None,
  )
  assert_eq(
    proxy_from_environment("https://localhost", name => values.get(name)),
    None,
  )
  values["NO_PROXY"] = "github.com"
  assert_eq(
    proxy_from_environment("https://api.github.com", name => values.get(name)),
    None,
  )
}

///|
test "NO_PROXY matches domain boundaries and optional ports" {
  assert_true(proxy_bypassed("127.0.0.2", 443, ""))
  assert_false(proxy_bypassed("127.external.example", 443, ""))
  assert_true(proxy_bypassed("github.com", 443, "github.com"))
  assert_true(proxy_bypassed("api.github.com", 443, "github.com:443"))
  assert_false(proxy_bypassed("notgithub.com", 443, "github.com"))
  assert_false(proxy_bypassed("github.com.evil.test", 443, "github.com"))
  assert_false(proxy_bypassed("github.com", 8443, "github.com:443"))
  assert_false(proxy_bypassed("github.com", 443, ".github.com"))
  assert_true(proxy_bypassed("api.github.com", 443, "*.github.com"))
  assert_true(proxy_bypassed("github.com", 443, " * "))
}

///|
test "unsupported and malformed proxy URLs fail without credential diagnostics" {
  for
    value in [
      "socks5://localhost:1080", "http://user:private-password@proxy.example:8080",
      "http://proxy.example/path", "http://proxy.example/?token=private", "http://proxy.example/#fragment",
      "http://proxy.example:99999", "http://proxy.example\r\nX-Injected: value",
    ] {
    let values = { "HTTPS_PROXY": value }
    try
      proxy_from_environment("https://github.com", name => values.get(name))
    catch {
      InvalidConfiguration => ()
      _ => fail("expected redacted configuration error")
    } noraise {
      _ => fail("invalid proxy was accepted")
    }
  }
}

///|
async test "HTTP proxy receives absolute target and origin Host without CONNECT" {
  let server = @http.Server(@socket.Addr::parse("127.0.0.1:0"))
  defer server.close()
  @async.with_timeout(3000, () => {
    @async.with_task_group() <| group => {
      group.spawn_bg() <| () => {
        let (conn, _) = server.accept()
        defer conn.close()
        let request = conn.read_request()
        assert_eq(request.meth, @http.Get)
        assert_eq(request.path, "http://origin.example/probe?x=1")
        assert_eq(request.headers.get("Host"), Some("origin.example"))
        assert_eq(
          request.headers.get("Authorization"),
          Some("Bearer fixture-only"),
        )
        conn..send_response(200, "OK")..write("proxied").end_response()
      }
      let client = connect_via_proxy(
        "http://origin.example",
        Some("http://127.0.0.1:\{server.addr.port()}"),
      )
      defer client.close()
      let target = proxy_request_target(
        "http://origin.example",
        "/probe?x=1",
        Some("http://proxy"),
      )
      let uri = @http_types.Uri::parse_request_target(target, Get).unwrap()
      let headers = raw_request_headers(
        [("Authorization", "Bearer fixture-only")],
        "http://origin.example",
      )
      let head = @http1.encode_request_head(
        { http_method: Get, uri, version: Http11, headers, body: (), },
        NoBody,
      ).unwrap()
      client.enter_passthrough_mode()
      client.write(head)
      let body = @buffer.Buffer()
      let response = read_raw_response_stream(
        client,
        Get,
        1024,
        @gh.RawResponseSink::new(headers=_ => true, chunk=bytes => {
          body.write_bytes(bytes)
        }),
      )
      assert_eq(response.head().status(), 200)
      assert_eq(body.to_bytes(), b"proxied")
    }
  })
}

///|
test "HTTPS proxy keeps an origin-form request within its TLS tunnel" {
  assert_eq(
    proxy_request_target(
      "https://api.github.com",
      "/user",
      Some("http://proxy"),
    ),
    "/user",
  )
  assert_eq(proxy_request_target("http://localhost", "/user", None), "/user")
}
