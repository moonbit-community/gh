///|
test "read retry policy accepts only bounded attempt and delay settings" {
  let defaults = @moonhub.ReadRetryPolicy::default()
  assert_eq(defaults.max_attempts, 3)
  assert_eq(defaults.initial_delay_ms, 100)
  assert_eq(defaults.max_delay_ms, 2000)
  for attempts in [0, 6, 2147483647] {
    assert_true(@moonhub.ReadRetryPolicy::new(max_attempts=attempts) is Err(_))
  }
  assert_true(@moonhub.ReadRetryPolicy::new(initial_delay_ms=-1) is Err(_))
  assert_true(@moonhub.ReadRetryPolicy::new(max_delay_ms=99) is Err(_))
  assert_true(@moonhub.ReadRetryPolicy::new(max_delay_ms=30001) is Err(_))
  assert_true(
    @moonhub.ReadRetryPolicy::new(
      max_attempts=1,
      initial_delay_ms=0,
      max_delay_ms=0,
    )
    is Ok(_),
  )
}

///|
async test "transient reads retain every request ID and combine trace failures across retries" {
  let records : Array[@gh.TraceRecord] = []
  let waits : Array[Int] = []
  let mut sends = 0
  let transport = @gh.Transport::new(origin="https://moonhub.example", send=_ => {
    @async.pause()
    sends += 1
    match sends {
      1 =>
        @gh.Response::new(status=503, body="private-body", headers=[
          ("X-Request-Id", "req-1"),
        ])
      2 =>
        @gh.Response::new(status=429, body="private-body", headers=[
          ("X-Request-Id", "req-2"),
          ("Retry-After", "1"),
        ])
      _ =>
        @gh.Response::new(status=200, body="{\"version\":1,\"data\":[]}", headers=[
          ("X-Request-Id", "req-3"),
        ])
    }
  })
  guard @moonhub.Client::new(
      config=@moonhub.ClientConfig::new(base_url="https://moonhub.example"),
      transport~,
      retry_wait=delay => {
        @async.pause()
        waits.push(delay)
      },
      trace=record => {
        @async.pause()
        records.push(record)
        if record.attempt == 1 {
          fail("sink unavailable")
        }
      },
    )
    is Ok(client) else {
    fail("client construction failed")
  }
  let result = client.repositories(operation_id="retry-success")
  assert_true(result.value is Ok([]))
  assert_eq(result.pages, 1)
  assert_true(result.trace_failed)
  assert_eq(waits, [100, 1000])
  assert_eq(sends, 3)
  assert_eq(records.map(record => record.attempt), [1, 2, 3])
  assert_eq(records.map(record => record.request_id), [
    Some("req-1"),
    Some("req-2"),
    Some("req-3"),
  ])
  assert_eq(records.map(record => record.status), [
    Some(503),
    Some(429),
    Some(200),
  ])
  assert_true(
    records.iter().all(record => record.operation_id == "retry-success"),
  )
}

///|
async test "retry attempts are continuous across pagination while each page has its own budget" {
  let records : Array[@gh.TraceRecord] = []
  let waits : Array[Int] = []
  let paths : Array[String] = []
  let transport = @gh.Transport::new(origin="https://moonhub.example", send=request => {
    @async.pause()
    paths.push(request.path)
    match paths.length() {
      1 => @gh.Response::new(status=502, body="")
      2 =>
        @gh.Response::new(status=200, body="{\"version\":1,\"data\":[]}", headers=[
          ("Link", "</api/v1/repos?page=2&per_page=30>; rel=next"),
        ])
      3 => fail("connection dropped")
      _ => @gh.Response::new(status=200, body="{\"version\":1,\"data\":[]}")
    }
  })
  guard @moonhub.Client::new(
      config=@moonhub.ClientConfig::new(base_url="https://moonhub.example"),
      transport~,
      retry_wait=delay => {
        @async.pause()
        waits.push(delay)
      },
      trace=record => {
        @async.pause()
        records.push(record)
      },
    )
    is Ok(client) else {
    fail("client construction failed")
  }
  let result = client.repositories(paginate=true, operation_id="retry-pages")
  assert_true(result.value is Ok([]))
  assert_eq(result.pages, 2)
  assert_eq(waits, [100, 100])
  assert_eq(paths, [
    "/api/v1/repos?page=1&per_page=30", "/api/v1/repos?page=1&per_page=30", "/api/v1/repos?page=2&per_page=30",
    "/api/v1/repos?page=2&per_page=30",
  ])
  assert_eq(records.map(record => record.attempt), [1, 2, 3, 4])
  assert_true(
    records.iter().all(record => record.operation_id == "retry-pages"),
  )
}

///|
async test "retryable failures stop at three attempts and return the final failure correlation" {
  for status in [0, 429, 502, 503, 504] {
    let waits : Array[Int] = []
    let mut sends = 0
    let transport = @gh.Transport::new(origin="https://moonhub.example", send=_ => {
      @async.pause()
      sends += 1
      if status == 0 {
        fail("network unavailable")
      }
      @gh.Response::new(status~, body="private-server-data", headers=[
        ("X-Request-Id", "request-\{sends}"),
      ])
    })
    guard @moonhub.Client::new(
        config=@moonhub.ClientConfig::new(base_url="https://moonhub.example"),
        transport~,
        retry_wait=delay => {
          @async.pause()
          waits.push(delay)
        },
      )
      is Ok(client) else {
      fail("client construction failed")
    }
    let result = client.repositories(operation_id="retry-exhausted")
    guard result.value is Err(error) else {
      fail("retry exhaustion became success")
    }
    assert_eq(result.pages, 0)
    assert_eq(sends, 3)
    assert_eq(waits, [100, 200])
    if status == 0 {
      assert_eq(error.kind.code(), "transport")
      assert_eq(error.request_id, None)
    } else {
      assert_eq(error.status, Some(status))
      assert_eq(error.request_id, Some("request-3"))
    }
  }
}

///|
async test "nontransient HTTP failures and malformed successful responses are never retried" {
  for
    response in [
      @gh.Response::new(status=401, body=""),
      @gh.Response::new(status=403, body=""),
      @gh.Response::new(status=409, body=""),
      @gh.Response::new(status=412, body=""),
      @gh.Response::new(status=500, body=""),
      @gh.Response::new(status=200, body="<html>not-json</html>"),
      @gh.Response::new(status=200, body="{\"version\":1,\"data\":[{}]}"),
    ] {
    let mut sends = 0
    let transport = @gh.Transport::new(origin="https://moonhub.example", send=_ => {
      @async.pause()
      sends += 1
      response
    })
    guard @moonhub.Client::new(
        config=@moonhub.ClientConfig::new(base_url="https://moonhub.example"),
        transport~,
        retry_wait=_ => fail("nontransient response entered retry wait"),
      )
      is Ok(client) else {
      fail("client construction failed")
    }
    assert_true(client.repositories(operation_id="no-retry").value is Err(_))
    assert_eq(sends, 1)
  }
}

///|
async test "unsupported or excessive Retry-After stops retries rather than shortening server delay" {
  for
    headers in [
      [("Retry-After", "3")],
      [("Retry-After", "99999999999999999999")],
      [("Retry-After", "Wed, 21 Oct 2026 07:28:00 GMT")],
      [("Retry-After", "-1")],
      [("Retry-After", "1.5")],
      [("Retry-After", " 1")],
      [("Retry-After", "")],
      [("Retry-After", "1, 1")],
      [("Retry-After", "1"), ("retry-after", "1")],
    ] {
    let mut sends = 0
    let transport = @gh.Transport::new(origin="https://moonhub.example", send=_ => {
      @async.pause()
      sends += 1
      @gh.Response::new(status=503, body="", headers~)
    })
    guard @moonhub.Client::new(
        config=@moonhub.ClientConfig::new(base_url="https://moonhub.example"),
        transport~,
        retry_wait=_ => fail("unsupported hint was ignored"),
      )
      is Ok(client) else {
      fail("client construction failed")
    }
    assert_true(
      client.repositories(operation_id="server-minimum").value is Err(_),
    )
    assert_eq(sends, 1)
  }
}

///|
async test "custom bounded backoff saturates and one attempt disables retry" {
  for attempts in [1, 5] {
    guard @moonhub.ReadRetryPolicy::new(
        max_attempts=attempts,
        initial_delay_ms=1500,
      )
      is Ok(read_retry) else {
      fail("invalid policy")
    }
    let mut sends = 0
    let waits : Array[Int] = []
    let transport = @gh.Transport::new(origin="https://moonhub.example", send=_ => {
      @async.pause()
      sends += 1
      @gh.Response::new(status=503, body="", headers=[("Retry-After", "0")])
    })
    guard @moonhub.Client::new(
        config=@moonhub.ClientConfig::new(base_url="https://moonhub.example"),
        transport~,
        read_retry~,
        retry_wait=delay => {
          @async.pause()
          waits.push(delay)
        },
      )
      is Ok(client) else {
      fail("client construction failed")
    }
    assert_true(
      client.repositories(operation_id="custom-bounds").value is Err(_),
    )
    assert_eq(sends, attempts)
    assert_eq(waits, if attempts == 1 { [] } else { [1500, 2000, 2000, 2000] })
  }
}

///|
async test "raw execute and mutations keep one attempt even on retryable statuses" {
  let mut sends = 0
  let transport = @gh.Transport::new(origin="https://moonhub.example", send=_ => {
    @async.pause()
    sends += 1
    @gh.Response::new(status=503, body="")
  })
  guard @moonhub.Client::new(
      config=@moonhub.ClientConfig::new(base_url="https://moonhub.example"),
      transport~,
      retry_wait=_ => fail("raw or mutation operation retried"),
    )
    is Ok(client) else {
    fail("client construction failed")
  }
  assert_true(
    client.execute(
      @gh.Request::new(verb=@gh.Get, path="/repos"),
      operation_id="raw-get",
    ).response
    is Err(_),
  )
  let mutation = client.create_issue(
    @moonhub.RepositoryRef::new(owner="team", name="demo"),
    title="example",
    operation_id="create-once",
  )
  assert_true(mutation.value is Err(_))
  assert_true(mutation.outcome is @moonhub.Unknown)
  assert_eq(sends, 2)
}

///|
async test "cancellation during backoff prevents the next network attempt" {
  let mut sends = 0
  let records : Array[@gh.TraceRecord] = []
  let transport = @gh.Transport::new(origin="https://moonhub.example", send=_ => {
    @async.pause()
    sends += 1
    @gh.Response::new(status=503, body="")
  })
  guard @moonhub.Client::new(
      config=@moonhub.ClientConfig::new(base_url="https://moonhub.example"),
      transport~,
      retry_wait=_ => @async.sleep(1000),
      trace=record => {
        @async.pause()
        records.push(record)
      },
    )
    is Ok(client) else {
    fail("client construction failed")
  }
  let cancelled = @async.with_timeout(10, () => {
    ignore(client.repositories(operation_id="cancel-wait"))
    false
  }) catch {
    _ => true
  }
  assert_true(cancelled)
  assert_eq(sends, 1)
  assert_eq(records.length(), 1)
  assert_eq(records[0].status, Some(503))
}

///|
async test "single-response typed schema failures retain sanitized request correlation" {
  for request_id in ["req-schema", "secret-token"] {
    guard @moonhub.resolve_token(
        base_url="https://moonhub.example",
        explicit="secret-token",
      )
      is Ok(Some(token)) else {
      fail("token setup failed")
    }
    let transport = @gh.Transport::new(origin="https://moonhub.example", send=_ => {
      @async.pause()
      @gh.Response::new(status=200, body="{\"version\":1,\"data\":[{}]}", headers=[
        ("X-Request-Id", request_id),
      ])
    })
    guard @moonhub.Client::new(
        config=@moonhub.ClientConfig::new(base_url="https://moonhub.example"),
        transport~,
        token~,
      )
      is Ok(client) else {
      fail("client construction failed")
    }
    let result = client.repositories(operation_id="decode-correlation")
    guard result.value is Err(error) else {
      fail("invalid resource was accepted")
    }
    assert_eq(error.kind.code(), "decode")
    assert_eq(error.status, Some(200))
    assert_eq(
      error.request_id,
      if request_id == "req-schema" {
        Some(request_id)
      } else {
        None
      },
    )
  }
}
