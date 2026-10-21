///|
async test "per request server retry preserves attempt traces without changing defaults" {
  let traces : Array[Json] = []
  let mut calls = 0
  guard @github.Client::new(
      config=@github.ClientConfig::new(base_url="https://api.github.com"),
      transport=@github.Transport::new(send=_ => {
        calls += 1
        Ok(@github.RawResponse::new(status=if calls == 4 { 200 } else { 503 }))
      }),
      trace_observer=record => traces.push(record.to_json()),
    )
    is Ok(client) else {
    fail("client")
  }
  assert_true(
    client.request(
      @github.Request::new(verb="GET", path="/meta"),
      retry_policy=@github.RetryPolicy::server_errors(
        max_attempts=4,
        delay_ms=0,
      ),
    )
    is Ok(_),
  )
  assert_eq(calls, 4)
  assert_eq(
    traces.map(value => {
      match value {
        { "attempt": attempt, .. } => attempt
        _ => Json::null()
      }
    }),
    [Json(1), Json(2), Json(3), Json(4)],
  )
  assert_true(
    client.request(@github.Request::new(verb="GET", path="/meta")) is Err(_),
  )
  assert_eq(calls, 5)
}

///|
async test "server retry excludes rate limits transport failures and mutation requests" {
  for
    (verb, status, expected) in [
      ("GET", 429, 1),
      ("GET", 499, 1),
      ("GET", 500, 4),
      ("GET", 599, 4),
      ("GET", 600, 1),
      ("HEAD", 503, 4),
      ("POST", 503, 1),
      ("DELETE", 503, 1),
      ("GET", 0, 1),
    ] {
    let mut calls = 0
    guard @github.Client::new(
        config=@github.ClientConfig::new(base_url="https://api.github.com"),
        transport=@github.Transport::new(send=_ => {
          calls += 1
          if status == 0 {
            Err(@github.TransportError::Failed)
          } else {
            Ok(@github.RawResponse::new(status~))
          }
        }),
        retry_policy=@github.RetryPolicy::limited(max_attempts=8),
      )
      is Ok(client) else {
      fail("client")
    }
    assert_true(
      client.request(
        @github.Request::new(verb~, path="/meta"),
        retry_policy=@github.RetryPolicy::server_errors(
          max_attempts=4,
          delay_ms=0,
        ),
      )
      is Err(_),
    )
    assert_eq(calls, expected)
  }
}
