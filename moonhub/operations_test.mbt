///|
async test "typed read operations use MoonHub native endpoints and GET only" {
  let sent : Array[String] = []
  let transport = @gh.Transport::new(origin="https://moonhub.example", send=request => {
    @async.pause()
    assert_eq(request.verb.as_string(), "GET")
    assert_eq(request.body, None)
    sent.push(request.path)
    let data : Json = match request.path {
      "/api/v1/meta" =>
        {
          "api_version": 1,
          "server_version": "0.1.0",
          "capabilities": ["issues", "merge_requests"],
        }
      "/api/v1/user" =>
        {
          "id": "1",
          "name_key": "alice",
          "display_name": "Alice",
          "is_site_admin": false,
        }
      "/api/v1/repos/team/demo" =>
        { "owner": "team", "name": "demo", "visibility": "private" }
      "/api/v1/repos?page=2&per_page=10" =>
        [{ "owner": "team", "name": "demo", "visibility": "public" }]
      "/api/v1/repos/team/demo/issues?page=1&per_page=30" =>
        [
          {
            "number": 7,
            "title": "An issue",
            "description": "",
            "status": "open",
          },
        ]
      "/api/v1/repos/team/demo/issues/7" =>
        {
          "number": 7,
          "title": "An issue",
          "description": "",
          "status": "open",
        }
      "/api/v1/repos/team/demo/merge-requests?page=1&per_page=30" =>
        [
          {
            "number": 3,
            "title": "An MR",
            "description": "",
            "status": "open",
            "source": "feature",
            "target": "main",
            "draft": false,
          },
        ]
      "/api/v1/repos/team/demo/merge-requests/3" =>
        {
          "number": 3,
          "title": "An MR",
          "description": "",
          "status": "merged",
          "source": "feature",
          "target": "main",
          "draft": false,
        }
      _ => fail("unexpected endpoint")
    }
    let envelope : Json = { "version": 1, "data": data }
    @gh.Response::new(status=200, body=envelope.stringify())
  })
  guard @moonhub.Client::new(
      config=@moonhub.ClientConfig::new(base_url="https://moonhub.example"),
      transport~,
    )
    is Ok(client) else {
    fail("client construction failed")
  }
  let repo = @moonhub.RepositoryRef::new(owner="team", name="demo")
  assert_true(
    client.meta(operation_id="read-meta").value is Ok(meta) &&
    meta.api_version == 1,
  )
  assert_true(
    client.current_user(operation_id="read-user").value is Ok(user) &&
    user.id == "1",
  )
  assert_true(
    client.repository(repo, operation_id="read-repo").value is Ok(repository) &&
    repository.name == "demo",
  )
  assert_true(
    client.repositories(page=2, per_page=10, operation_id="read-repos").value
    is Ok([repository]) &&
    repository.visibility == "public",
  )
  assert_true(
    client.issues(repo, operation_id="read-issues").value is Ok([issue]) &&
    issue.number == 7,
  )
  assert_true(
    client.issue(repo, 7, operation_id="read-issue").value is Ok(issue) &&
    issue.status == "open",
  )
  assert_true(
    client.merge_requests(repo, operation_id="read-mrs").value is Ok([mr]) &&
    mr.number == 3,
  )
  assert_true(
    client.merge_request(repo, 3, operation_id="read-mr").value is Ok(mr) &&
    mr.status == "merged",
  )
  assert_eq(sent.length(), 8)
}

///|
async test "invalid read arguments never send requests" {
  let mut sends = 0
  let transport = @gh.Transport::new(origin="https://moonhub.example", send=_ => {
    @async.pause()
    sends += 1
    @gh.Response::new(status=200, body="{\"version\":1,\"data\":[]}")
  })
  guard @moonhub.Client::new(
      config=@moonhub.ClientConfig::new(base_url="https://moonhub.example"),
      transport~,
    )
    is Ok(client) else {
    fail("client construction failed")
  }
  let repo = @moonhub.RepositoryRef::new(owner="team", name="demo")
  let bad = @moonhub.RepositoryRef::new(owner="assets", name="demo")
  assert_true(
    client.repository(bad, operation_id="invalid").value is Err(error) &&
    error.kind.code() == "invalid_request",
  )
  assert_true(client.issue(repo, 0, operation_id="invalid").value is Err(_))
  assert_true(
    client.merge_request(repo, -1, operation_id="invalid").value is Err(_),
  )
  assert_true(
    client.repositories(page=0, operation_id="invalid").value is Err(_),
  )
  assert_true(
    client.repositories(page=1000001, operation_id="invalid").value is Err(_),
  )
  assert_true(
    client.issues(repo, per_page=101, operation_id="invalid").value is Err(_),
  )
  assert_true(
    client.merge_requests(repo, per_page=0, operation_id="invalid").value
    is Err(_),
  )
  assert_eq(sends, 0)
}

///|
async test "typed decode failure is sanitized and preserves trace failure metadata" {
  let transport = @gh.Transport::new(origin="https://moonhub.example", send=_ => {
    @async.pause()
    @gh.Response::new(
      status=200,
      body="{\"version\":1,\"data\":{\"number\":1,\"title\":\"private-secret\",\"description\":\"\",\"status\":\"unknown\"}}",
    )
  })
  guard @moonhub.Client::new(
      config=@moonhub.ClientConfig::new(base_url="https://moonhub.example"),
      transport~,
      trace=_ => {
        @async.pause()
        fail("sink unavailable")
      },
    )
    is Ok(client) else {
    fail("client construction failed")
  }
  let result = client.issue(
    @moonhub.RepositoryRef::new(owner="team", name="demo"),
    1,
    operation_id="bad-data",
  )
  assert_true(result.trace_failed)
  assert_eq(result.pages, 1)
  guard result.value is Err(error) && error.kind is @gh.Decode(message~) else {
    fail("malformed resource became success")
  }
  assert_eq(message, "invalid MoonHub resource response")
}

///|
async test "typed list decoding refuses partial data when one resource is malformed" {
  let transport = @gh.Transport::new(origin="https://moonhub.example", send=_ => {
    @async.pause()
    @gh.Response::new(
      status=200,
      body="{\"version\":1,\"data\":[{\"number\":1,\"title\":\"ok\",\"description\":\"\",\"status\":\"open\"},{\"number\":2,\"title\":\"bad\",\"description\":\"\",\"status\":\"future\"}]}",
    )
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
    operation_id="bad-list",
  )
  assert_true(result.value is Err(error) && error.kind.code() == "decode")
}

///|
async test "resource reads discard mismatched identities and their mutation tags" {
  let mut sends = 0
  let transport = @gh.Transport::new(origin="https://moonhub.example", send=request => {
    @async.pause()
    sends += 1
    let data : Json = match request.path {
      "/api/v1/repos/team/demo" =>
        { "owner": "other", "name": "demo", "visibility": "private" }
      "/api/v1/repos/team/other" =>
        { "owner": "team", "name": "wrong", "visibility": "private" }
      "/api/v1/repos/team/demo/issues/7" =>
        {
          "number": 99,
          "title": "private-title",
          "description": "",
          "status": "open",
        }
      "/api/v1/repos/team/demo/merge-requests/3" =>
        {
          "number": 99,
          "title": "private-title",
          "description": "",
          "status": "open",
          "source": "feature",
          "target": "main",
          "draft": false,
        }
      _ => fail("unexpected identity test path")
    }
    let envelope : Json = { "version": 1, "data": data }
    @gh.Response::new(status=200, body=envelope.stringify(), headers=[
      ("ETag", "\"other-resource\""),
    ])
  })
  guard @moonhub.Client::new(
      config=@moonhub.ClientConfig::new(base_url="https://moonhub.example"),
      transport~,
      trace=_ => {
        @async.pause()
        fail("sink unavailable")
      },
    )
    is Ok(client) else {
    fail("client construction failed")
  }
  let repo = @moonhub.RepositoryRef::new(owner="team", name="demo")
  let wrong_owner = client.repository(repo, operation_id="wrong-owner")
  let wrong_name = client.repository(
    @moonhub.RepositoryRef::new(owner="team", name="other"),
    operation_id="wrong-name",
  )
  let issue = client.issue(repo, 7, operation_id="wrong-issue")
  let mr = client.merge_request(repo, 3, operation_id="wrong-mr")
  assert_true(wrong_owner.value is Err(error) && error.kind.code() == "decode")
  assert_true(wrong_name.value is Err(error) && error.kind.code() == "decode")
  assert_true(mr.value is Err(error) && error.kind.code() == "decode")
  guard issue.value is Err(error) && error.kind is @gh.Decode(message~) else {
    fail("mismatched issue became success")
  }
  assert_eq(message, "MoonHub response does not match the requested resource")
  assert_true(wrong_owner.etag is None)
  assert_true(wrong_name.etag is None)
  assert_true(issue.etag is None)
  assert_true(mr.etag is None)
  assert_true(issue.next is None)
  assert_eq(issue.pages, 1)
  assert_true(issue.trace_failed)
  assert_eq(sends, 4)
}
