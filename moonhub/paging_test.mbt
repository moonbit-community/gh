///|
async test "pagination joins typed pages and shares operation ID across traced attempts" {
  let requests : Array[String] = []
  let records : Array[@gh.TraceRecord] = []
  let transport = @gh.Transport::new(origin="https://moonhub.example", send=request => {
    @async.pause()
    requests.push(request.path)
    let (body, headers) = match request.path {
      "/api/v1/repos/team/demo/issues?page=1&per_page=1" =>
        (
          "{\"version\":1,\"data\":[{\"number\":7,\"title\":\"first\",\"description\":\"\",\"status\":\"open\"}]}",
          [
            (
              "Link", "</api/v1/repos/team/demo/issues?page=2&per_page=1>; rel=\"next\"",
            ),
          ],
        )
      "/api/v1/repos/team/demo/issues?page=2&per_page=1" =>
        (
          "{\"version\":1,\"data\":[{\"number\":8,\"title\":\"second\",\"description\":\"\",\"status\":\"closed\"}]}",
          [],
        )
      _ => fail("unexpected page")
    }
    @gh.Response::new(status=200, body~, headers~)
  })
  guard @moonhub.Client::new(
      config=@moonhub.ClientConfig::new(base_url="https://moonhub.example"),
      transport~,
      trace=record => {
        @async.pause()
        records.push(record)
        if record.attempt == 1 {
          fail("first sink write unavailable")
        }
      },
    )
    is Ok(client) else {
    fail("client construction failed")
  }
  let result = client.issues(
    @moonhub.RepositoryRef::new(owner="team", name="demo"),
    per_page=1,
    paginate=true,
    operation_id="read-many",
  )
  guard result.value is Ok([first, second]) else {
    fail("pages not aggregated")
  }
  assert_eq(first.number, 7)
  assert_eq(second.number, 8)
  assert_eq(result.pages, 2)
  assert_eq(result.next, None)
  assert_true(result.trace_failed)
  assert_eq(requests.length(), 2)
  assert_eq(records.length(), 2)
  assert_eq(records[0].operation_id, "read-many")
  assert_eq(records[1].operation_id, "read-many")
  assert_eq(records[0].attempt, 1)
  assert_eq(records[1].attempt, 2)
  assert_eq(records[0].path, "/api/v1/repos/team/demo/issues")
}

///|
async test "single page returns validated continuation without following it" {
  let mut sends = 0
  let transport = @gh.Transport::new(origin="https://moonhub.example", send=_ => {
    @async.pause()
    sends += 1
    @gh.Response::new(status=200, body="{\"version\":1,\"data\":[]}", headers=[
      (
        "Link", "<https://moonhub.example/api/v1/repos?page=2&per_page=30>; rel=\"next\"",
      ),
    ])
  })
  guard @moonhub.Client::new(
      config=@moonhub.ClientConfig::new(base_url="https://moonhub.example"),
      transport~,
    )
    is Ok(client) else {
    fail("client construction failed")
  }
  let result = client.repositories(operation_id="one-page")
  assert_true(result.value is Ok([]))
  assert_eq(result.next, Some("/repos?page=2&per_page=30"))
  assert_eq(result.pages, 1)
  assert_eq(sends, 1)
}

///|
async test "repeated Link fields are combined before following or rejecting next links" {
  let next = "</api/v1/repos?page=2&per_page=30>; rel=next"
  let padding = StringBuilder()
  for _ in 0..<32768 {
    padding.write_char(' ')
  }
  let padding = padding.to_string()
  for
    (headers, valid) in [
      (
        [
          ("Link", "</api/v1/repos?page=1&per_page=30>; rel=prev"),
          ("lInK", next),
        ],
        true,
      ),
      ([("Link", next), ("lInK", next)], false),
      ([("Link", padding), ("link", padding)], false),
    ] {
    let requests : Array[String] = []
    let transport = @gh.Transport::new(origin="https://moonhub.example", send=request => {
      @async.pause()
      requests.push(request.path)
      @gh.Response::new(
        status=200,
        body="{\"version\":1,\"data\":[]}",
        headers=if requests.length() == 1 { headers } else { [] },
      )
    })
    guard @moonhub.Client::new(
        config=@moonhub.ClientConfig::new(base_url="https://moonhub.example"),
        transport~,
      )
      is Ok(client) else {
      fail("client construction failed")
    }
    let result = client.repositories(
      paginate=true,
      operation_id="repeated-link",
    )
    assert_eq(result.next, None)
    if valid {
      assert_true(result.value is Ok([]))
      assert_eq(result.pages, 2)
      assert_eq(requests, [
        "/api/v1/repos?page=1&per_page=30", "/api/v1/repos?page=2&per_page=30",
      ])
    } else {
      assert_true(result.value is Err(error) && error.kind.code() == "decode")
      assert_eq(result.pages, 1)
      assert_eq(requests.length(), 1)
    }
  }
}

///|
async test "single page rejects unsafe continuation and item budget overflow" {
  let empty : Json = { "version": 1, "data": [] }
  let oversized : Json = {
    "version": 1,
    "data": Json::array(Array::make(1001, Json::null())),
  }
  for
    (body, headers) in [
      (
        empty.stringify(),
        [
          (
            "Link", "<https://evil.example/api/v1/repos?page=2&per_page=30>; rel=\"next\"",
          ),
        ],
      ),
      (oversized.stringify(), []),
    ] {
    let mut sends = 0
    let transport = @gh.Transport::new(origin="https://moonhub.example", send=_ => {
      @async.pause()
      sends += 1
      @gh.Response::new(status=200, body~, headers~)
    })
    guard @moonhub.Client::new(
        config=@moonhub.ClientConfig::new(base_url="https://moonhub.example"),
        transport~,
      )
      is Ok(client) else {
      fail("client construction failed")
    }
    let result = client.repositories(operation_id="bounded-single")
    assert_true(result.value is Err(error) && error.kind.code() == "decode")
    assert_eq(result.next, None)
    assert_eq(sends, 1)
  }
}

///|
async test "unsafe links and exhausted page budget never cause another request" {
  for
    link in [
      "<https://evil.example/api/v1/repos?page=2&per_page=30>; rel=\"next\"", "</api/v1/repos?page=1&per_page=30>; rel=\"next\"",
      "</api/v1/repos?page=2&per_page=30>; rel=\"next\"",
    ] {
    let mut sends = 0
    let transport = @gh.Transport::new(origin="https://moonhub.example", send=_ => {
      @async.pause()
      sends += 1
      @gh.Response::new(status=200, body="{\"version\":1,\"data\":[]}", headers=[
        ("Link", link),
      ])
    })
    guard @moonhub.Client::new(
        config=@moonhub.ClientConfig::new(base_url="https://moonhub.example"),
        transport~,
      )
      is Ok(client) else {
      fail("client construction failed")
    }
    let result = client.repositories(
      paginate=true,
      max_pages=1,
      operation_id="bounded",
    )
    assert_true(result.value is Err(error) && error.kind.code() == "decode")
    assert_eq(result.pages, 1)
    assert_eq(result.next, None)
    assert_eq(sends, 1)
  }
}

///|
async test "a later failed HTTP or malformed page discards all partial typed data" {
  for
    second in [
      @gh.Response::new(
        status=403,
        body="{\"version\":1,\"error\":{\"code\":\"forbidden\",\"message\":\"private-secret\"}}",
      ),
      @gh.Response::new(status=200, body="<html>private-secret</html>"),
      @gh.Response::new(
        status=200,
        body="{\"version\":1,\"data\":[{\"number\":2,\"title\":\"private-secret\",\"description\":\"\",\"status\":\"invalid\"}]}",
      ),
    ] {
    let mut sends = 0
    let transport = @gh.Transport::new(origin="https://moonhub.example", send=_ => {
      @async.pause()
      sends += 1
      if sends == 1 {
        @gh.Response::new(
          status=200,
          body="{\"version\":1,\"data\":[{\"number\":1,\"title\":\"first\",\"description\":\"\",\"status\":\"open\"}]}",
          headers=[
            (
              "Link", "</api/v1/repos/team/demo/issues?page=2&per_page=30>; rel=\"next\"",
            ),
          ],
        )
      } else {
        second
      }
    })
    guard @moonhub.Client::new(
        config=@moonhub.ClientConfig::new(base_url="https://moonhub.example"),
        transport~,
      )
      is Ok(client) else {
      fail("client construction failed")
    }
    let result = client.issues(
      @moonhub.RepositoryRef::new(owner="team", name="demo"),
      paginate=true,
      operation_id="failed-later",
    )
    guard result.value is Err(error) else {
      fail("partial data reported as success")
    }
    assert_true(error.kind.code() is ("forbidden" | "decode"))
    assert_eq(result.next, None)
    assert_eq(sends, 2)
  }
}

///|
async test "success envelope and list shapes are strict including version and null data" {
  for
    body in [
      "{\"version\":2,\"data\":[]}", "{\"version\":1.5,\"data\":[]}", "{\"version\":\"1\",\"data\":[]}",
      "{\"version\":1}", "{\"version\":1,\"data\":null}", "{\"version\":1,\"data\":{}}",
    ] {
    let transport = @gh.Transport::new(origin="https://moonhub.example", send=_ => {
      @async.pause()
      @gh.Response::new(status=200, body~)
    })
    guard @moonhub.Client::new(
        config=@moonhub.ClientConfig::new(base_url="https://moonhub.example"),
        transport~,
      )
      is Ok(client) else {
      fail("client construction failed")
    }
    let result = client.repositories(operation_id="invalid-envelope")
    assert_true(result.value is Err(error) && error.kind.code() == "decode")
    assert_eq(result.next, None)
  }
}
