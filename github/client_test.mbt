///|
async test "REST request builds URL, GitHub headers, bearer auth, and bytes" {
  let seen : Array[@github.Request] = []
  let transport = @github.Transport::new(send=request => {
    seen.push(request)
    Ok(
      @github.RawResponse::new(
        status=200,
        headers=[
          ("X-@github.Request-Id", "req-1"),
          ("X-Repeat", "one"),
          ("x-repeat", "two"),
        ],
        body=[0, 255, 1],
      ),
    )
  })
  let config = @github.ClientConfig::new(
    base_url="https://api.github.example",
    token="secret-token",
    user_agent="test-gh",
  )
  guard @github.Client::new(config~, transport~) is Ok(client) else {
    fail("client construction failed")
  }
  let result = client.request(
    @github.Request::new(
      verb="GET",
      path="/repos/acme/demo",
      query=[("q", "hello world"), ("tag", "a+b")],
      headers=[("X-Trace", "enabled")],
    ),
  )
  guard result is Ok(response) else { fail("REST request failed") }
  assert_eq(response.status(), 200)
  assert_eq(response.body(), [0, 255, 1])
  assert_eq(response.header("x-repeat"), Some("one"))
  assert_eq(seen.length(), 1)
  assert_eq(seen[0].verb(), "GET")
  assert_eq(seen[0].path(), "/repos/acme/demo")
  assert_eq(
    seen[0].url(),
    "https://api.github.example/repos/acme/demo?q=hello%20world&tag=a%2Bb",
  )
  assert_true(
    seen[0].headers().contains(("Authorization", "Bearer secret-token")),
  )
  assert_true(
    seen[0].headers().contains(("Accept", "application/vnd.github+json")),
  )
  assert_true(
    seen[0].headers().contains(("X-GitHub-Api-Version", "2022-11-28")),
  )
  assert_true(seen[0].headers().contains(("User-Agent", "test-gh")))
}

///|
async test "empty successful REST response remains an empty raw body" {
  let transport = @github.Transport::new(send=_ => {
    Ok(@github.RawResponse::new(status=204))
  })
  guard @github.Client::new(
      config=@github.ClientConfig::new(base_url="https://api.github.example"),
      transport~,
    )
    is Ok(client) else {
    fail("client construction failed")
  }
  guard client.request(
      @github.Request::new(verb="DELETE", path="/user/starred/acme/demo"),
    )
    is Ok(response) else {
    fail("empty response was rejected")
  }
  assert_eq(response.status(), 204)
  assert_true(response.body().is_empty())
  assert_eq(response.body_text(), Ok(""))
}

///|
async test "GraphQL errors retain the raw response and decoded errors" {
  let seen : Array[@github.Request] = []
  let transport = @github.Transport::new(send=request => {
    seen.push(request)
    Ok(
      @github.RawResponse::new(
        status=200,
        body=@utf8.encode("{\"errors\":[{\"message\":\"bad query\"}] }"),
      ),
    )
  })
  guard @github.Client::new(
      config=@github.ClientConfig::new(base_url="https://ghe.example/api/v3"),
      transport~,
    )
    is Ok(client) else {
    fail("client construction failed")
  }
  let result = client.graphql(
    @github.GraphQLRequest::new(
      query="query CurrentUser { viewer { login } }",
      operation_name="CurrentUser",
      variables=Json::object({ "enabled": Json::boolean(true) }),
    ),
  )
  match result {
    Err(GraphQL(response~, errors~)) => {
      assert_eq(response.status(), 200)
      assert_eq(errors.length(), 1)
      assert_true(errors[0].stringify().contains("bad query"))
      assert_eq(seen.length(), 1)
      assert_eq(seen[0].url(), "https://ghe.example/api/graphql")
      guard seen[0].body() is Some(body) else {
        fail("GraphQL request body was absent")
      }
      let body_text = @utf8.decode(body) catch {
        _ => fail("GraphQL body was not UTF-8")
      }
      assert_true(body_text.contains("CurrentUser"))
    }
    _ => fail("GraphQL errors were not surfaced")
  }
}

///|
async test "default retry policy makes exactly one attempt" {
  let mut calls = 0
  let transport = @github.Transport::new(send=_ => {
    calls += 1
    Ok(@github.RawResponse::new(status=503, body=@utf8.encode("busy")))
  })
  guard @github.Client::new(
      config=@github.ClientConfig::new(base_url="https://api.github.example"),
      transport~,
    )
    is Ok(client) else {
    fail("client construction failed")
  }
  match client.request(@github.Request::new(verb="GET", path="/rate_limit")) {
    Err(Server(status~, response~)) => {
      assert_eq(status, 503)
      assert_eq(response.body_text(), Ok("busy"))
    }
    _ => fail("HTTP failure was not returned")
  }
  assert_eq(calls, 1)
}

///|
async test "explicit retry policy retries transient statuses" {
  let mut calls = 0
  let transport = @github.Transport::new(send=_ => {
    calls += 1
    if calls == 1 {
      Ok(@github.RawResponse::new(status=503))
    } else {
      Ok(@github.RawResponse::new(status=200, body=[42]))
    }
  })
  guard @github.Client::new(
      config=@github.ClientConfig::new(base_url="https://api.github.example"),
      transport~,
      retry_policy=@github.RetryPolicy::limited(max_attempts=2),
    )
    is Ok(client) else {
    fail("client construction failed")
  }
  guard client.request(@github.Request::new(verb="GET", path="/rate_limit"))
    is Ok(response) else {
    fail("explicit retry did not recover")
  }
  assert_eq(response.status(), 200)
  assert_eq(calls, 2)
}

///|
/// HTTP statuses retain a stable protocol category while callers can still
/// inspect the original status and response bytes through the common accessors.
async test "HTTP error protocol categories preserve status and body" {
  for
    (status, expected_code) in [
      (401, "authentication"),
      (403, "permission"),
      (404, "http"),
      (409, "conflict"),
      (422, "validation"),
      (429, "rate_limited"),
      (500, "server"),
    ] {
    let transport = @github.Transport::new(send=_ => {
      Ok(
        @github.RawResponse::new(
          status~,
          body=@utf8.encode("{\"status\":{status}}"),
        ),
      )
    })
    let client = match
      @github.Client::new(
        config=@github.ClientConfig::new(base_url="https://api.github.example"),
        transport~,
      ) {
      Ok(value) => value
      Err(_) => fail("client construction failed")
    }
    let result = client.request(
      @github.Request::new(verb="GET", path="/fixture"),
    )
    match result {
      Err(error) => {
        assert_eq(error.code(), expected_code)
        assert_eq(error.status(), Some(status))
        guard error.response() is Some(response) else {
          fail("error lost its raw response")
        }
        assert_eq(response.status(), status)
        assert_true(!response.body().is_empty())
      }
      Ok(_) => fail("HTTP error unexpectedly succeeded")
    }
  }
}

///|
async test "forbidden rate limit responses are classified by metadata" {
  let transport = @github.Transport::new(send=_ => {
    Ok(
      @github.RawResponse::new(status=403, headers=[
        ("X-RateLimit-Remaining", "0"),
      ]),
    )
  })
  let client = match
    @github.Client::new(
      config=@github.ClientConfig::new(base_url="https://api.github.example"),
      transport~,
    ) {
    Ok(value) => value
    Err(_) => fail("client construction failed")
  }
  match client.request(@github.Request::new(verb="GET", path="/fixture")) {
    Err(error) => assert_eq(error.code(), "rate_limited")
    Ok(_) => fail("rate limit unexpectedly succeeded")
  }
}

///|
async test "secondary rate limit message classifies a headerless 403" {
  let transport = @github.Transport::new(send=_ => {
    Ok(
      @github.RawResponse::new(
        status=403,
        body=@utf8.encode(
          "{\"message\":\"You have exceeded a secondary rate limit.\"}",
        ),
      ),
    )
  })
  let client = match
    @github.Client::new(
      config=@github.ClientConfig::new(base_url="https://api.github.example"),
      transport~,
    ) {
    Ok(value) => value
    Err(_) => fail("client construction failed")
  }
  match client.request(@github.Request::new(verb="GET", path="/fixture")) {
    Err(error) => assert_eq(error.code(), "rate_limited")
    Ok(_) => fail("secondary rate limit unexpectedly succeeded")
  }
}

///|
test "REST pagination links reject cross-origin and malformed next targets" {
  let current_url = "https://api.github.example/repos/acme/widgets/issues?page=1"
  match
    @github.next_link(
      "<https://api.github.example/repos/acme/widgets/issues?page=2>; rel=\"next\"",
      current_url~,
    ) {
    Ok(Some(value)) =>
      assert_eq(
        value, "https://api.github.example/repos/acme/widgets/issues?page=2",
      )
    _ => fail("valid pagination link was rejected")
  }
  assert_true(
    @github.next_link(
      "<https://evil.example/repos/acme/widgets/issues?page=2>; rel=\"next\"",
      current_url~,
    )
    is Err(_),
  )
  assert_true(
    @github.next_link(
      "<https://api.github.example/repos/acme/widgets/issues?page=2>; rel=\"next",
      current_url~,
    )
    is Err(_),
  )
}

///|
async test "transport cancellation remains a distinct client error" {
  let transport = @github.Transport::new(send=_ => {
    Err(@github.TransportError::Cancelled)
  })
  let client = match
    @github.Client::new(
      config=@github.ClientConfig::new(base_url="https://api.github.example"),
      transport~,
    ) {
    Ok(value) => value
    Err(_) => fail("client construction failed")
  }
  match client.request(@github.Request::new(verb="GET", path="/fixture")) {
    Err(@github.Cancelled) => ()
    _ => fail("transport cancellation was converted to another error")
  }
}

///|
async test "release upload origin is restricted to the matching uploads host" {
  let mut seen_url = ""
  let transport = @github.Transport::new(send=request => {
    seen_url = request.url()
    Ok(@github.RawResponse::new(status=201, body=b"{}"))
  })
  let client = match
    @github.Client::new(
      config=@github.ClientConfig::new(base_url="https://api.github.example"),
      transport~,
    ) {
    Ok(value) => value
    Err(_) => fail("client construction failed")
  }
  let response = client.request(
    @github.Request::new(
      verb="POST",
      path="/repos/acme/widgets/releases/42/assets",
      query=[("name", "tool.bin")],
      headers=[("Content-Type", "application/octet-stream")],
      body=b"asset",
      origin="https://uploads.github.example",
    ),
  )
  assert_true(response is Ok(_))
  assert_eq(
    seen_url, "https://uploads.github.example/repos/acme/widgets/releases/42/assets?name=tool.bin",
  )
  match
    client.request(
      @github.Request::new(
        verb="POST",
        path="/repos/acme/widgets/releases/42/assets",
        origin="https://evil.example",
      ),
    ) {
    Err(error) => assert_eq(error.code(), "invalid_configuration")
    Ok(_) => fail("untrusted alternate origin was accepted")
  }
}
