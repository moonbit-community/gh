///|
async test "injected client sends credentials and emits only redacted attempt metadata" {
  guard @moonhub.resolve_token(
      base_url="https://moonhub.example",
      explicit="top-secret-token",
    )
    is Ok(Some(token)) else {
    fail("token resolution failed")
  }
  let sent : Array[@gh.Request] = []
  let records : Array[@gh.TraceRecord] = []
  let transport = @gh.Transport::new(origin="https://moonhub.example", send=request => {
    @async.pause()
    sent.push(request)
    @gh.Response::new(status=201, body="{\"body\":\"private-text\"}", headers=[
      ("X-Request-Id", "top-secret-token"),
    ])
  })
  let mut time = 100L
  guard @moonhub.Client::new(
      config=@moonhub.ClientConfig::new(base_url="https://moonhub.example/"),
      transport~,
      token~,
      trace=record => {
        @async.pause()
        records.push(record)
      },
      clock=() => {
        time += 12
        time
      },
    )
    is Ok(client) else {
    fail("client creation failed")
  }
  let result = client.execute(
    @gh.Request::new(
      verb=@gh.Post,
      path="/repos/team/demo/issues?q=top-secret-token",
      body="private-text",
    ),
    operation_id="op-create",
    attempt=3,
  )
  assert_true(result.response is Ok(_))
  assert_false(result.trace_failed)
  assert_eq(sent.length(), 1)
  assert_eq(sent[0].path, "/api/v1/repos/team/demo/issues?q=top-secret-token")
  assert_true(
    sent[0].headers.contains(("Authorization", "Bearer top-secret-token")),
  )
  assert_eq(sent[0].body, Some("private-text"))
  assert_eq(records.length(), 1)
  assert_eq(records[0].attempt, 3)
  assert_eq(records[0].duration_ms, Some(12L))
  assert_eq(records[0].status, Some(201))
  let line = records[0].to_json_line()
  assert_false(line.contains("top-secret-token"))
  assert_false(line.contains("private-text"))
  assert_eq(records[0].path, "/api/v1/repos/team/demo/issues")
  assert_true(records[0].request_id is None)
}

///|
async test "transport failure is sanitized and a mutation is never retried" {
  let mut sends = 0
  let records : Array[@gh.TraceRecord] = []
  let transport = @gh.Transport::new(origin="https://moonhub.example", send=_ => {
    @async.pause()
    sends += 1
    fail("network exception contains secret-token")
  })
  guard @moonhub.Client::new(
      config=@moonhub.ClientConfig::new(base_url="https://moonhub.example"),
      transport~,
      trace=record => {
        @async.pause()
        records.push(record)
      },
    )
    is Ok(client) else {
    fail("client creation failed")
  }
  let result = client.execute(
    @gh.Request::new(verb=@gh.Post, path="/issues", body="private-body"),
    operation_id="op-failed",
  )
  match result.response {
    Err(err) => {
      assert_eq(err.kind.code(), "transport")
      assert_true(err.status is None)
      match err.kind {
        @gh.Transport(message~) =>
          assert_false(message.contains("secret-token"))
        _ => fail("wrong failure category")
      }
    }
    Ok(_) => fail("transport failure became success")
  }
  assert_eq(sends, 1)
  assert_eq(records.length(), 1)
  assert_eq(records[0].error_code, Some("transport"))
  assert_false(records[0].to_json_line().contains("private-body"))
}

///|
async test "sink failure preserves the completed HTTP outcome" {
  let transport = @gh.Transport::new(origin="https://moonhub.example", send=_ => {
    @async.pause()
    @gh.Response::new(status=201, body="{\"number\":42}")
  })
  guard @moonhub.Client::new(
      config=@moonhub.ClientConfig::new(base_url="https://moonhub.example"),
      transport~,
      trace=_ => {
        @async.pause()
        fail("disk full secret path")
      },
    )
    is Ok(client) else {
    fail("client creation failed")
  }
  let result = client.execute(
    @gh.Request::new(verb=@gh.Post, path="/issues"),
    operation_id="op-sink",
  )
  assert_true(result.response is Ok(response) && response.status == 201)
  assert_true(result.trace_failed)
}

///|
async test "invalid paths and reserved headers never reach transport" {
  let mut sends = 0
  let transport = @gh.Transport::new(origin="https://moonhub.example", send=_ => {
    @async.pause()
    sends += 1
    @gh.Response::new(status=200, body="{}")
  })
  let config = @moonhub.ClientConfig::new(base_url="https://moonhub.example")
  guard @moonhub.Client::new(config~, transport~) is Ok(client) else {
    fail("client creation failed")
  }
  for
    request in [
      @gh.Request::new(verb=@gh.Get, path="//evil.example/user"),
      @gh.Request::new(verb=@gh.Get, path="/../outside"),
      @gh.Request::new(verb=@gh.Get, path="/user", headers=[
        ("AUTHORIZATION", "other-token"),
      ]),
      @gh.Request::new(verb=@gh.Get, path="/user", headers=[
        ("Accept", "application/json"),
        ("accept", "text/plain"),
      ]),
      @gh.Request::new(verb=@gh.Get, path="/user", headers=[
        ("Expect", "100-continue"),
      ]),
      @gh.Request::new(verb=@gh.Get, path="/user", headers=[
        ("Accept-Encoding", "gzip"),
      ]),
    ] {
    let result = client.execute(request, operation_id="op-invalid")
    assert_true(
      result.response is Err(err) && err.kind.code() == "invalid_request",
    )
  }
  assert_eq(sends, 0)
  assert_true(
    @moonhub.Client::new(
      config=@moonhub.ClientConfig::new(base_url="https://other.example"),
      transport~,
    )
    is Err(_),
  )
  guard @moonhub.resolve_token(
      base_url="https://other.example",
      explicit="other-token",
    )
    is Ok(Some(token)) else {
    fail("token resolution failed")
  }
  assert_true(@moonhub.Client::new(config~, transport~, token~) is Err(_))
}

///|
async test "HTTP failures carry status code and correlation into trace" {
  let records : Array[@gh.TraceRecord] = []
  let transport = @gh.Transport::new(origin="https://moonhub.example", send=_ => {
    @async.pause()
    let body =
      #|{"version":1,"error":{"code":"conflict","message":"secret"},"request_id":"req-7"}
    @gh.Response::new(status=412, body~)
  })
  guard @moonhub.Client::new(
      config=@moonhub.ClientConfig::new(base_url="https://moonhub.example"),
      transport~,
      trace=record => {
        @async.pause()
        records.push(record)
      },
    )
    is Ok(client) else {
    fail("client creation failed")
  }
  let result = client.execute(
    @gh.Request::new(verb=@gh.Patch, path="/issues/1"),
    operation_id="op-conflict",
  )
  assert_true(result.response is Err(err) && err.kind.code() == "conflict")
  assert_eq(records[0].request_id, Some("req-7"))
  assert_eq(records[0].status, Some(412))
  assert_eq(records[0].error_code, Some("conflict"))
}

///|
async test "cancellation propagates and records a cancelled attempt" {
  let records : Array[@gh.TraceRecord] = []
  let transport = @gh.Transport::new(origin="https://moonhub.example", send=_ => {
    @async.sleep(1000)
    @gh.Response::new(status=200, body="{}")
  })
  guard @moonhub.Client::new(
      config=@moonhub.ClientConfig::new(base_url="https://moonhub.example"),
      transport~,
      trace=record => {
        @async.pause()
        records.push(record)
      },
    )
    is Ok(client) else {
    fail("client creation failed")
  }
  let mut cancelled = false
  @async.with_timeout(20, () => {
    ignore(
      client.execute(
        @gh.Request::new(verb=@gh.Get, path="/user"),
        operation_id="op-cancel",
      ),
    )
  }) catch {
    _ => cancelled = true
  }
  assert_true(cancelled)
  assert_eq(records.length(), 1)
  assert_eq(records[0].error_code, Some("cancelled"))
}

///|
async test "a stuck completion sink is bounded and preserves the HTTP response" {
  let transport = @gh.Transport::new(origin="https://moonhub.example", send=_ => {
    @async.pause()
    @gh.Response::new(status=201, body="{}")
  })
  guard @moonhub.Client::new(
      config=@moonhub.ClientConfig::new(base_url="https://moonhub.example"),
      transport~,
      trace=_ => @async.sleep(5000),
    )
    is Ok(client) else {
    fail("client creation failed")
  }
  let result = @async.with_timeout(2500, () => {
    client.execute(
      @gh.Request::new(verb=@gh.Post, path="/issues"),
      operation_id="op-slow-sink",
    )
  })
  assert_true(result.response is Ok(response) && response.status == 201)
  assert_true(result.trace_failed)
}

///|
async test "cancellation during completion recording does not erase the response" {
  let mut result_observed = false
  let mut sink_started = false
  let transport = @gh.Transport::new(origin="https://moonhub.example", send=_ => {
    @async.pause()
    @gh.Response::new(status=201, body="{}")
  })
  guard @moonhub.Client::new(
      config=@moonhub.ClientConfig::new(base_url="https://moonhub.example"),
      transport~,
      trace=_ => {
        sink_started = true
        @async.sleep(50)
      },
    )
    is Ok(client) else {
    fail("client creation failed")
  }
  @async.with_task_group() <| group => {
    let task = group.spawn(() => {
      let outcome = client.execute(
        @gh.Request::new(verb=@gh.Post, path="/issues"),
        operation_id="op-cancel-after-response",
      )
      result_observed = outcome.response is Ok(response) &&
        response.status == 201
    })
    while !sink_started {
      @async.pause()
    }
    task.cancel()
    task.wait() catch {
      _ => ()
    }
  }
  assert_true(result_observed)
}
