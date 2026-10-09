///|
/// Real loopback HTTP + SDK auth/error handling + a real append-only trace file.
/// This is a contract fixture, not a claim of MoonHub server interoperability.
async test "native composition sends authenticated JSON and persists sanitized outcomes" {
  let directory = @fs.tmpdir(prefix="gh-client-")
  defer @fs.rmdir(directory, recursive=true)
  let trace_path = directory + "/trace.jsonl"
  @async.with_task_group() <| group => {
    let server = @http.Server(@socket.Addr::parse("127.0.0.1:0"))
    defer server.close()
    group.spawn_bg() <| () => {
      for status in [201, 412] {
        let (conn, _) = server.accept()
        defer conn.close()
        let request = conn.read_request()
        assert_eq(request.path, "/api/v1/fixture?token=fixture-secret")
        assert_eq(
          request.headers.get("Authorization"),
          Some("Bearer fixture-secret"),
        )
        assert_eq(request.headers.get("Content-Type"), Some("application/json"))
        assert_eq(conn.read_all().text(), "{\"private\":\"request-body\"}")
        conn.send_response(status, "Fixture", extra_headers={
          "X-Request-Id": "fixture-id",
        })
        let body = if status == 201 {
          "{\"number\":7}"
        } else {
          "{\"version\":1,\"error\":{\"code\":\"conflict\",\"message\":\"fixture-secret response-body\"}}"
        }
        conn..write(body).end_response()
      }
    }
    guard @native.client(
        base_url="http://127.0.0.1:\{server.addr.port()}",
        token="fixture-secret",
        trace_path~,
      )
      is Ok(client) else {
      fail("native client setup failed")
    }
    let request = @gh.Request::new(
      verb=@gh.Post,
      path="/fixture?token=fixture-secret",
      body="{\"private\":\"request-body\"}",
    )
    let first = client.execute(request, operation_id="op-1")
    assert_true(first.response is Ok(response) && response.status == 201)
    assert_false(first.trace_failed)
    let second = client.execute(request, operation_id="op-2")
    assert_true(
      second.response is Err(error) && error.kind.code() == "conflict",
    )
    assert_false(second.trace_failed)
  }
  let text = @fs.read_file(trace_path).text()
  let lines = text.trim_end(chars="\n").split("\n").collect()
  assert_eq(lines.length(), 2)
  assert_true(
    @json.parse(lines[0])
    is {
      "status": 201,
      "path": "/api/v1/fixture",
      "request_id": "fixture-id",
      ..
    },
  )
  assert_true(
    @json.parse(lines[1]) is { "status": 412, "error_code": "conflict", .. },
  )
  for
    secret in [
      "fixture-secret", "request-body", "response-body", "Authorization",
    ] {
    assert_false(text.contains(secret))
  }
}

///|
async test "native setup rejects wrong credential origin configuration before I/O" {
  assert_true(
    @native.client(base_url="https://moonhub.example", token="", trace_path="-")
    is Err(_),
  )
  assert_true(
    @native.client(
      base_url="https://moonhub.example",
      token="valid-token",
      timeout_ms=0,
    )
    is Err(_),
  )
}
