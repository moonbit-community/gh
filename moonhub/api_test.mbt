///|
fn api_test_client(
  send~ : async (@gh.Request) -> @gh.Response,
  trace? : async (@gh.TraceRecord) -> Unit,
  token? : @moonhub.Token,
) -> @moonhub.Client raise {
  let transport = @gh.Transport::new(origin="https://moonhub.example", send~)
  guard @moonhub.Client::new(
      config=@moonhub.ClientConfig::new(base_url="https://moonhub.example"),
      transport~,
      trace?,
      token?,
    )
    is Ok(client) else {
    fail("API client construction failed")
  }
  client
}

///|
async test "generic JSON API preserves methods raw bodies and complete response values" {
  let sent : Array[@gh.Request] = []
  let client = api_test_client(send=request => {
    @async.pause()
    sent.push(request)
    @gh.Response::new(
      status=201,
      body="{\"version\":17,\"future\":[1,true,null],\"large\":9007199254740993}",
      headers=[
        ("ETag", "\"future-tag\""),
        ("X-Request-Id", "req-extension"),
        ("Set-Cookie", "private-cookie"),
      ],
    )
  })
  let body = " {\"large\":9007199254740993,\"label\":\"你好\"} \n"
  for verb in [@gh.Post, @gh.Put, @gh.Patch, @gh.Delete] {
    let result = client.api(
      @gh.Request::new(verb~, path="/extensions/jobs?filter=ready", body~, headers=[
        ("If-Match", "\"caller-tag\""),
        ("X-Client-Feature", "jobs"),
      ]),
      operation_id="api-write",
    )
    assert_true(result.outcome is Some(@moonhub.Applied))
    assert_false(result.trace_failed)
    guard result.value is Ok(response) else {
      fail("valid API response rejected")
    }
    assert_eq(response.status, 201)
    assert_true(
      response.data is { "version": Number(17, ..), "future": Array(_), .. },
    )
    assert_true(response.data.stringify().contains("9007199254740993"))
    assert_eq(response.request_id, Some("req-extension"))
    assert_true(response.etag is Some(tag) && tag.value() == "\"future-tag\"")
  }
  assert_eq(sent.length(), 4)
  for index in 0..<sent.length() {
    assert_eq(
      sent[index].verb.as_string(),
      ["POST", "PUT", "PATCH", "DELETE"][index],
    )
    assert_eq(sent[index].body, Some(body))
    assert_eq(sent[index].path, "/api/v1/extensions/jobs?filter=ready")
    assert_true(sent[index].headers.contains(("If-Match", "\"caller-tag\"")))
    assert_true(
      sent[index].headers.contains(("Content-Type", "application/json")),
    )
  }
}

///|
async test "generic API distinguishes absent body JSON null and no-content responses" {
  let sent : Array[@gh.Request] = []
  let client = api_test_client(send=request => {
    @async.pause()
    sent.push(request)
    match request.path {
      "/api/v1/no-content" => @gh.Response::new(status=204, body="")
      "/api/v1/reset-content" => @gh.Response::new(status=205, body="")
      "/api/v1/accepted" => @gh.Response::new(status=202, body="null")
      _ => @gh.Response::new(status=200, body="[true,\"future\",null]")
    }
  })
  for path in ["/no-content", "/reset-content"] {
    let result = client.api(
      @gh.Request::new(verb=@gh.Delete, path~),
      operation_id="empty-response",
    )
    assert_true(result.value is Ok(response) && response.data is Null)
    assert_true(result.outcome is Some(@moonhub.Applied))
  }
  let accepted = client.api(
    @gh.Request::new(verb=@gh.Post, path="/accepted", body="null"),
    operation_id="accepted",
  )
  assert_true(accepted.outcome is Some(@moonhub.Accepted))
  assert_true(accepted.value is Ok(response) && response.data is Null)
  let read = client.api(
    @gh.Request::new(verb=@gh.Get, path="/extensions"),
    operation_id="read",
  )
  assert_true(read.outcome is None)
  assert_true(read.value is Ok(response) && response.data is Array(_))
  assert_eq(sent[0].body, None)
  assert_eq(sent[2].body, Some("null"))
  assert_false(
    sent[0].headers.any(pair => pair.0.equal_ignore_ascii_case("content-type")),
  )
  assert_true(sent[2].headers.contains(("Content-Type", "application/json")))
}

///|
async test "generic API rejects unsafe and unbounded input without network or trace" {
  let mut sends = 0
  let mut traces = 0
  let client = api_test_client(
    send=_ => {
      @async.pause()
      sends += 1
      @gh.Response::new(status=200, body="{}")
    },
    trace=_ => {
      @async.pause()
      traces += 1
    },
  )
  for
    path in [
      "user",
      "https://other.example/user",
      "//other.example/user",
      "/../user",
      "/%2e%2e/user",
      "/user#fragment",
      "/api/v1",
      "/api/v1/user",
      "/api/v1?q=x",
      "/" + "x".repeat(4096),
    ] {
    let result = client.api(
      @gh.Request::new(verb=@gh.Post, path~),
      operation_id="invalid-path",
    )
    assert_true(
      result.value is Err(error) && error.kind.code() == "invalid_request",
    )
    assert_true(result.outcome is Some(@moonhub.NotSent))
  }
  for
    body in [
      "",
      " ",
      "{",
      "true false",
      "private-body",
      "\"" + "é".repeat(40000) + "\"",
    ] {
    let result = client.api(
      @gh.Request::new(verb=@gh.Post, path="/extensions", body~),
      operation_id="invalid-body",
    )
    assert_true(
      result.value is Err(error) && error.kind.code() == "invalid_request",
    )
    assert_true(result.outcome is Some(@moonhub.NotSent))
  }
  let get = client.api(
    @gh.Request::new(verb=@gh.Get, path="/extensions", body="null"),
    operation_id="get-body",
  )
  assert_true(get.value is Err(_))
  assert_true(get.outcome is None)
  assert_eq(sends, 0)
  assert_eq(traces, 0)
  assert_true(
    @moonhub.validate_api_request(
      @gh.Request::new(
        verb=@gh.Post,
        path="/extensions",
        body="\"" + "é".repeat(39999) + "\"",
      ),
    )
    is Ok(_),
  )
}

///|
test "generic API header policy protects credentials framing routing and JSON" {
  for
    name in [
      "Authorization", "Proxy-Authorization", "Cookie", "Cookie2", "Host", "Content-Length",
      "Transfer-Encoding", "Connection", "Upgrade", "Expect", "Proxy-Connection",
      "TE", "Trailer", "Keep-Alive", "Forwarded", "X-Forwarded-Host", "X-Forwarded-Proto",
      "X-HTTP-Method-Override", "X-HTTP-Method", "X-Method-Override", "X-Original-URL",
      "X-Rewrite-URL", "Api-Key", "X-API-Key", "X-Auth-Token", "X-Access-Token",
    ] {
    assert_true(
      @moonhub.validate_api_request(
        @gh.Request::new(verb=@gh.Post, path="/extensions", headers=[
          (name, "private-value"),
        ]),
      )
      is Err(_),
    )
  }
  for
    headers in [
      [("Accept", "text/html")],
      [("Content-Type", "text/plain")],
      [("Accept-Encoding", "gzip")],
      [("If-Match", "W/\"weak\"")],
      [("If-Match", "*")],
      [("If-Match", "\"a\", \"b\"")],
      [("X-Feature", "one"), ("x-feature", "two")],
      [("X-Feature", "line\r\nbreak")],
      [("X-Feature", "中文")],
      [("X-Feature", "x".repeat(4097))],
      [("x".repeat(129), "value")],
      [("X-First", "x".repeat(4096)), ("X-Second", "y".repeat(4096))],
    ] {
    assert_true(
      @moonhub.validate_api_request(
        @gh.Request::new(verb=@gh.Post, path="/extensions", headers~),
      )
      is Err(_),
    )
  }
  let headers : Array[(String, String)] = []
  for index in 0..<32 {
    headers.push(("X-Field-\{index}", "value"))
  }
  assert_true(
    @moonhub.validate_api_request(
      @gh.Request::new(verb=@gh.Post, path="/extensions", headers~),
    )
    is Ok(_),
  )
  headers.push(("X-Field-32", "value"))
  assert_true(
    @moonhub.validate_api_request(
      @gh.Request::new(verb=@gh.Post, path="/extensions", headers~),
    )
    is Err(_),
  )
  assert_true(
    @moonhub.validate_api_request(
      @gh.Request::new(verb=@gh.Post, path="/extensions", body="false", headers=[
        ("Accept", "application/json"),
        ("Content-Type", "application/json"),
        ("Accept-Encoding", "identity"),
        ("If-Match", "\"strong\""),
      ]),
    )
    is Ok(_),
  )
}

///|
async test "generic API keeps ambiguous outcomes and never retries or follows redirects" {
  let responses : Array[@gh.Response?] = [
    None,
    Some(
      @gh.Response::new(status=503, body="private-server-error", headers=[
        ("Retry-After", "0"),
      ]),
    ),
    Some(
      @gh.Response::new(status=302, body="", headers=[
        ("Location", "https://other.example"),
      ]),
    ),
    Some(@gh.Response::new(status=201, body="private-invalid-json")),
    Some(@gh.Response::new(status=204, body="null")),
    Some(@gh.Response::new(status=205, body=" ")),
    Some(@gh.Response::new(status=200, body="")),
    Some(
      @gh.Response::new(status=200, body="null", headers=[
        ("ETag", "W/\"weak\""),
      ]),
    ),
    Some(
      @gh.Response::new(status=200, body="null", headers=[
        ("ETag", "\"a\""),
        ("ETag", "\"b\""),
      ]),
    ),
  ]
  for response in responses {
    let mut sends = 0
    let records : Array[@gh.TraceRecord] = []
    let client = api_test_client(
      send=_ => {
        @async.pause()
        sends += 1
        match response {
          Some(value) => value
          None => fail("private-network-detail")
        }
      },
      trace=record => {
        @async.pause()
        records.push(record)
      },
    )
    let write = client.api(
      @gh.Request::new(verb=@gh.Post, path="/extensions"),
      operation_id="write",
    )
    assert_true(write.value is Err(_))
    assert_true(write.outcome is Some(@moonhub.Unknown))
    let read = client.api(
      @gh.Request::new(verb=@gh.Get, path="/extensions"),
      operation_id="read",
    )
    assert_true(read.value is Err(_))
    assert_true(read.outcome is None)
    assert_eq(sends, 2)
    assert_eq(records.length(), 2)
    assert_eq(records[0].attempt, 1)
    assert_eq(records[1].attempt, 1)
  }
}

///|
async test "generic API HTTP rejections retain safe correlation and local errors are not sent" {
  for status in [400, 401, 403, 404, 409, 412, 429] {
    let mut sends = 0
    let client = api_test_client(send=_ => {
      @async.pause()
      sends += 1
      @gh.Response::new(status~, body="private-failure-body", headers=[
        ("X-Request-Id", "req-rejected"),
      ])
    })
    let result = client.api(
      @gh.Request::new(verb=@gh.Patch, path="/extensions"),
      operation_id="rejected",
    )
    assert_true(result.outcome is Some(@moonhub.Rejected))
    guard result.value is Err(error) else {
      fail("HTTP rejection became success")
    }
    assert_eq(error.status, Some(status))
    assert_eq(error.request_id, Some("req-rejected"))
    let invalid = client.api(
      @gh.Request::new(verb=@gh.Delete, path="/extensions"),
      operation_id="invalid operation",
    )
    assert_true(invalid.outcome is Some(@moonhub.NotSent))
    assert_eq(sends, 1)
  }
  let malformed = api_test_client(send=_ => {
    @async.pause()
    @gh.Response::new(status=201, body="private-malformed", headers=[
      ("X-Request-Id", "req-decode"),
    ])
  })
  let result = malformed.api(
    @gh.Request::new(verb=@gh.Post, path="/extensions"),
    operation_id="decode",
  )
  guard result.value is Err(error) else {
    fail("malformed API response became success")
  }
  assert_eq(error.kind.code(), "decode")
  assert_eq(error.status, Some(201))
  assert_eq(error.request_id, Some("req-decode"))
}

///|
async test "generic API trace redacts inputs and sink failure preserves acceptance" {
  guard @moonhub.resolve_token(
      base_url="https://moonhub.example",
      explicit="private-token",
    )
    is Ok(Some(token)) else {
    fail("token resolution failed")
  }
  let records : Array[@gh.TraceRecord] = []
  let client = api_test_client(
    token~,
    send=request => {
      @async.pause()
      assert_true(
        request.headers.contains(("Authorization", "Bearer private-token")),
      )
      @gh.Response::new(status=202, body="{\"value\":\"private-response\"}", headers=[
        ("X-Request-Id", "private-token"),
      ])
    },
    trace=record => {
      @async.pause()
      records.push(record)
      fail("private-sink-failure")
    },
  )
  let result = client.api(
    @gh.Request::new(
      verb=@gh.Post,
      path="/extensions?query=private-query",
      body="\"private-body\"",
      headers=[
        ("X-Feature", "private-header"),
        ("If-Match", "\"private-etag\""),
      ],
    ),
    operation_id="redacted",
  )
  assert_true(result.outcome is Some(@moonhub.Accepted))
  assert_true(result.trace_failed)
  assert_true(result.value is Ok(response) && response.request_id is None)
  assert_eq(records.length(), 1)
  let line = records[0].to_json_line()
  for
    secret in [
      "private-token", "private-query", "private-body", "private-header", "private-etag",
      "private-response", "private-sink-failure",
    ] {
    assert_false(line.contains(secret))
  }
  assert_eq(records[0].path, "/api/v1/extensions")
}
