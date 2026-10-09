///|
async test "review resource integers retain exact wire precision" {
  for
    (spelling, accepted) in [
      ("1.0000000000000001", false),
      ("2147483647.00000001", false),
      ("1", true),
      ("1.0", true),
      ("10e-1", true),
      ("0.1e1", true),
    ] {
    let transport = @gh.Transport::new(origin="https://moonhub.example", send=_ => {
      @async.pause()
      @gh.Response::new(
        status=200,
        body="{\"version\":1,\"data\":{\"number\":\{spelling},\"title\":\"x\",\"description\":\"\",\"status\":\"open\"}}",
      )
    })
    guard @moonhub.Client::new(
        config=@moonhub.ClientConfig::new(base_url="https://moonhub.example"),
        transport~,
      )
      is Ok(client) else {
      fail("client")
    }
    let result = client.issue(
      @moonhub.RepositoryRef::new(owner="team", name="demo"),
      1,
      operation_id="number",
    )
    assert_eq(result.value is Ok(_), accepted)
  }
}

///|
async test "review rejects rounded envelope versions in reads writes and auth" {
  let version = "1.0000000000000001"
  assert_true(
    @moonhub.resolve_token(
      base_url="https://moonhub.example",
      config_json="{\"version\":\{version},\"hosts\":{}}",
    )
    is Err(_),
  )
  let transport = @gh.Transport::new(origin="https://moonhub.example", send=_ => {
    @async.pause()
    @gh.Response::new(
      status=201,
      body="{\"version\":\{version},\"data\":{\"number\":1,\"title\":\"x\",\"description\":\"\",\"status\":\"open\"}}",
      headers=[("ETag", "\"one\"")],
    )
  })
  guard @moonhub.Client::new(
      config=@moonhub.ClientConfig::new(base_url="https://moonhub.example"),
      transport~,
    )
    is Ok(client) else {
    fail("client")
  }
  let repo = @moonhub.RepositoryRef::new(owner="team", name="demo")
  assert_true(client.issue(repo, 1, operation_id="read").value is Err(_))
  let write = client.create_issue(repo, title="x", operation_id="write")
  assert_true(write.value is Err(_))
  assert_true(write.outcome is @moonhub.Unknown)
  guard @moonhub.decode_response(
      @gh.Response::new(
        status=401,
        body="{\"version\":\{version},\"error\":{\"code\":\"unauthorized\"},\"request_id\":\"untrusted-version\"}",
      ),
    )
    is Err(error) else {
    fail("401 must remain an error")
  }
  assert_eq(error.kind.code(), "unauthorized")
  assert_eq(error.request_id, None)
}

///|
async test "review malformed first page stops pagination and keeps response context" {
  let mut sends = 0
  let transport = @gh.Transport::new(origin="https://moonhub.example", send=_ => {
    @async.pause()
    sends += 1
    @gh.Response::new(
      status=200,
      body=if sends == 1 {
        "{\"version\":1,\"data\":[{\"number\":1,\"title\":\"bad\",\"description\":\"\",\"status\":\"future\"}]}"
      } else {
        "{\"version\":1,\"data\":[]}"
      },
      headers=if sends == 1 {
        [
          ("X-Request-Id", "bad-page"),
          (
            "Link", "</api/v1/repos/team/demo/issues?page=2&per_page=30>; rel=next",
          ),
        ]
      } else {
        []
      },
    )
  })
  guard @moonhub.Client::new(
      config=@moonhub.ClientConfig::new(base_url="https://moonhub.example"),
      transport~,
    )
    is Ok(client) else {
    fail("client")
  }
  let result = client.issues(
    @moonhub.RepositoryRef::new(owner="team", name="demo"),
    paginate=true,
    operation_id="bad-page",
  )
  assert_eq(sends, 1)
  guard result.value is Err(error) else { fail("invalid resource accepted") }
  assert_eq(error.kind.code(), "decode")
  assert_eq(error.status, Some(200))
  assert_eq(error.request_id, Some("bad-page"))
  assert_eq(result.next, None)
}

///|
async test "review second page failure discards partial data and retains its ID" {
  let mut sends = 0
  let transport = @gh.Transport::new(origin="https://moonhub.example", send=_ => {
    @async.pause()
    sends += 1
    @gh.Response::new(
      status=200,
      body="{\"version\":1,\"data\":[{\"number\":\{sends},\"title\":\"item\",\"description\":\"\",\"status\":\"\{if sends == 1 { "open" } else { "bad" }}\"}]}",
      headers=[
        ("X-Request-Id", "page-\{sends}"),
        ("Link", "<?page=\{sends + 1}&per_page=30>; rel=next"),
      ],
    )
  })
  guard @moonhub.Client::new(
      config=@moonhub.ClientConfig::new(base_url="https://moonhub.example"),
      transport~,
    )
    is Ok(client) else {
    fail("client")
  }
  let result = client.issues(
    @moonhub.RepositoryRef::new(owner="team", name="demo"),
    paginate=true,
    operation_id="pages",
  )
  assert_eq(sends, 2)
  assert_eq(result.pages, 2)
  guard result.value is Err(error) else {
    fail("partial data must not succeed")
  }
  assert_eq(error.request_id, Some("page-2"))
  assert_eq(error.status, Some(200))
  assert_eq(result.next, None)
}

///|
async test "review generic API keeps numeric response payload exact" {
  let body = "{\"number\":9007199254740993,\"fraction\":1.0000000000000001,\"tiny\":1e-999}"
  let transport = @gh.Transport::new(origin="https://moonhub.example", send=_ => {
    @async.pause()
    @gh.Response::new(status=200, body~)
  })
  guard @moonhub.Client::new(
      config=@moonhub.ClientConfig::new(base_url="https://moonhub.example"),
      transport~,
    )
    is Ok(client) else {
    fail("client")
  }
  guard client.api(
      @gh.Request::new(verb=@gh.Get, path="/example"),
      operation_id="raw",
    ).value
    is Ok(response) else {
    fail("API decode")
  }
  assert_eq(response.data.stringify(), body)
}
