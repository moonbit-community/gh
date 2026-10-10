///|
async test "native adapter sends all methods, bearer headers, and UTF-8 bodies" {
  let server = @http.Server(@socket.Addr::parse("127.0.0.1:0"))
  defer server.close()
  @async.with_task_group() <| group => {
    let methods = [@gh.Get, Post, Put, Patch, Delete]
    group.spawn_bg() <| () => {
      for verb in methods {
        let (conn, _) = server.accept()
        defer conn.close()
        let request = conn.read_request()
        assert_eq(request.path, "/api/v1/echo?q=moon")
        assert_eq(
          request.meth,
          match verb {
            Get => @http.Get
            Post => Post
            Put => Put
            Patch => Patch
            Delete => Delete
          },
        )
        assert_eq(
          request.headers.get("Authorization"),
          Some("Bearer fixture-token"),
        )
        assert_eq(request.headers.get("User-Agent"), Some("fixture-client"))
        assert_eq(request.headers.get("Accept-Encoding"), Some("identity"))
        assert_eq(conn.read_all().text(), "{\"title\":\"月亮\"}")
        conn.send_response(201, "Created", extra_headers={
          "X-Request-Id": "fixture-request-id",
        })
        conn..write("{\"ok\":true}").end_response()
      }
    }
    let transport = @transport.native_transport(
      base_url="http://127.0.0.1:\{server.addr.port()}",
    )
    for verb in methods {
      let response = transport.send(
        @gh.Request::new(
          verb~,
          path="/api/v1/echo?q=moon",
          body="{\"title\":\"月亮\"}",
          headers=[
            ("Authorization", "Bearer fixture-token"),
            ("User-Agent", "fixture-client"),
          ],
        ),
      )
      assert_eq(response.status, 201)
      assert_eq(response.body, "{\"ok\":true}")
      assert_eq(response.header("x-request-id"), Some("fixture-request-id"))
    }
  }
}

///|
async fn with_response(
  status : Int,
  body : String,
  run : async (@gh.Transport) -> Unit,
  max_response_bytes? : Int = 8388608,
  headers? : @http.Headers = Map([]),
) -> Unit {
  let server = @http.Server(@socket.Addr::parse("127.0.0.1:0"))
  defer server.close()
  @async.with_task_group() <| group => {
    group.spawn_bg() <| () => {
      let (conn, _) = server.accept()
      defer conn.close()
      ignore(conn.read_request())
      conn.send_response(status, "Fixture", extra_headers=headers)
      conn..write(body).end_response()
    }
    run(
      @transport.native_transport(
        base_url="http://127.0.0.1:\{server.addr.port()}",
        max_response_bytes~,
      ),
    )
  }
}

///|
async test "redirect response is returned without following Location" {
  with_response(
    302,
    "redirect",
    headers={ "Location": "https://must-not-contact.invalid/secret" },
  ) <| transport => {
    let response = transport.send(
      @gh.Request::new(verb=Get, path="/api/v1/user", headers=[
        ("Authorization", "Bearer fixture-token"),
      ]),
    )
    assert_eq(response.status, 302)
    assert_eq(response.body, "redirect")
    assert_eq(
      response.header("Location"),
      Some("https://must-not-contact.invalid/secret"),
    )
  }
}

///|
async test "response cap accepts exact bytes and rejects oversize" {
  with_response(200, "月a", max_response_bytes=4) <| transport => {
    assert_eq(
      transport.send(@gh.Request::new(verb=Get, path="/api/v1/user")).body,
      "月a",
    )
  }
  with_response(200, "月ab", max_response_bytes=4) <| transport => {
    let failed = try {
      ignore(transport.send(@gh.Request::new(verb=Get, path="/api/v1/user")))
      false
    } catch {
      _ => true
    }
    assert_true(failed)
  }
}

///|
async test "timeout includes waiting for response headers" {
  let server = @http.Server(@socket.Addr::parse("127.0.0.1:0"))
  defer server.close()
  @async.with_task_group() <| group => {
    group.spawn_bg(no_wait=true) <| () => {
      let (conn, _) = server.accept()
      defer conn.close()
      ignore(conn.read_request())
      @async.sleep(5000)
    }
    let transport = @transport.native_transport(
      base_url="http://127.0.0.1:\{server.addr.port()}",
      timeout_ms=50,
    )
    let timed_out = try {
      ignore(transport.send(@gh.Request::new(verb=Get, path="/api/v1/user")))
      false
    } catch {
      @async.TimeoutError => true
      _ => false
    }
    assert_true(timed_out)
  }
}

///|
test "configuration rejects insecure origins and nonpositive limits" {
  for
    base_url in [
      "http://moonhub.example", "https://user:secret@moonhub.example", "https://moonhub.example/api/v1",
    ] {
    let failed = try {
      ignore(@transport.native_transport(base_url~))
      false
    } catch {
      _ => true
    }
    assert_true(failed)
  }
  let failed = try {
    ignore(
      @transport.native_transport(
        base_url="https://moonhub.example",
        timeout_ms=0,
      ),
    )
    false
  } catch {
    _ => true
  }
  assert_true(failed)
  let failed = try {
    ignore(
      @transport.native_transport(
        base_url="https://moonhub.example",
        max_response_bytes=0,
      ),
    )
    false
  } catch {
    _ => true
  }
  assert_true(failed)
}
