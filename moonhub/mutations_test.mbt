///|
fn mutation_test_client(
  send~ : async (@gh.Request) -> @gh.Response,
  trace? : async (@gh.TraceRecord) -> Unit,
) -> @moonhub.Client raise {
  let transport = @gh.Transport::new(origin="https://moonhub.example", send~)
  guard @moonhub.Client::new(
      config=@moonhub.ClientConfig::new(base_url="https://moonhub.example"),
      transport~,
      trace?,
    )
    is Ok(client) else {
    fail("mutation client construction failed")
  }
  client
}

///|
fn mutation_test_tag() -> @moonhub.EntityTag raise {
  guard @moonhub.EntityTag::parse("\"opaque-current-tag\"") is Ok(tag) else {
    fail("valid opaque ETag rejected")
  }
  tag
}

///|
fn mutation_test_issue(status? : String = "open") -> String {
  let envelope : Json = {
    "version": 1,
    "data": {
      "number": 7,
      "title": "An issue",
      "description": "private-description",
      "status": status.to_json(),
      "edit_version": "2",
    },
  }
  envelope.stringify()
}

///|
fn mutation_test_merge_request() -> String {
  let envelope : Json = {
    "version": 1,
    "data": {
      "number": 3,
      "title": "An MR",
      "description": "private-description",
      "source": "feature/api",
      "target": "main",
      "draft": false,
      "status": "open",
      "version": "5",
      "edit_version": "2",
    },
  }
  envelope.stringify()
}

///|
async test "mutations send one MoonHub POST with exact body and caller precondition" {
  let sent : Array[@gh.Request] = []
  let client = mutation_test_client(send=request => {
    @async.pause()
    sent.push(request)
    assert_eq(request.verb.as_string(), "POST")
    let (status, body) = match request.path {
      "/api/v1/repos/team/demo/issues" => (201, mutation_test_issue())
      "/api/v1/repos/team/demo/issues/7/comments" =>
        (201, "{\"version\":1,\"data\":{\"number\":7,\"kind\":\"commented\"}}")
      "/api/v1/repos/team/demo/issues/7/close" =>
        (200, mutation_test_issue(status="closed"))
      "/api/v1/repos/team/demo/issues/7/reopen" => (200, mutation_test_issue())
      "/api/v1/repos/team/demo/merge-requests" =>
        (201, mutation_test_merge_request())
      "/api/v1/repos/team/demo/merge-requests/3/comments" =>
        (201, "{\"version\":1,\"data\":{\"number\":3,\"kind\":\"commented\"}}")
      "/api/v1/repos/team/demo/merge-requests/3/merge" =>
        (
          202, "{\"version\":1,\"data\":{\"number\":3,\"version\":\"5\",\"job_status\":\"pending\"}}",
        )
      _ => fail("unexpected mutation route")
    }
    @gh.Response::new(status~, body~, headers=[("ETag", "\"opaque-next-tag\"")])
  })
  let repo = @moonhub.RepositoryRef::new(owner="team", name="demo")
  let if_match = mutation_test_tag()
  let created = client.create_issue(
    repo,
    title="An issue",
    description="private-description",
    operation_id="create-issue",
  )
  assert_true(created.value is Ok(issue) && issue.number == 7)
  assert_true(created.outcome is @moonhub.Applied)
  assert_true(created.etag is Some(tag) && tag.value() == "\"opaque-next-tag\"")
  assert_true(
    client.comment_issue(
      repo,
      7,
      body="comment \"quoted\"\n中文",
      operation_id="comment-issue",
    ).value
    is Ok(receipt) &&
    receipt.kind == "commented",
  )
  assert_true(
    client.close_issue(repo, 7, if_match~, operation_id="close-issue").value
    is Ok(issue) &&
    issue.status == "closed",
  )
  assert_true(
    client.reopen_issue(repo, 7, if_match~, operation_id="reopen-issue").value
    is Ok(issue) &&
    issue.status == "open",
  )
  assert_true(
    client.create_merge_request(
      repo,
      title="An MR",
      description="private-description",
      source="feature/api",
      target="main",
      operation_id="create-mr",
    ).value
    is Ok(mr) &&
    mr.status == "open",
  )
  assert_true(
    client.comment_merge_request(
      repo,
      3,
      body="review context",
      if_match~,
      operation_id="comment-mr",
    ).value
    is Ok(receipt) &&
    receipt.number == 3,
  )
  let queued = client.merge_merge_request(
    repo,
    3,
    if_match~,
    operation_id="merge-mr",
  )
  assert_true(
    queued.value is Ok(receipt) &&
    receipt.job_status == "pending" &&
    receipt.version == "5",
  )
  assert_true(queued.outcome is @moonhub.Accepted)
  assert_eq(sent.length(), 7)
  for index, request in sent {
    let conditional = index == 2 || index == 3 || index == 5 || index == 6
    assert_eq(
      request.headers.contains(("If-Match", "\"opaque-current-tag\"")),
      conditional,
    )
    if !conditional {
      assert_false(
        request.headers.any(pair => pair.0.equal_ignore_ascii_case("if-match")),
      )
    }
  }
  assert_true(
    @json.parse(sent[0].body.unwrap())
    is {
      "title": String("An issue"),
      "description": String("private-description"),
      ..
    },
  )
  assert_true(
    @json.parse(sent[1].body.unwrap())
    is { "body": String("comment \"quoted\"\n中文"), .. },
  )
  assert_eq(sent[2].body, Some("{}"))
  assert_eq(sent[3].body, Some("{}"))
  assert_true(
    @json.parse(sent[4].body.unwrap())
    is {
      "source": String("feature/api"),
      "target": String("main"),
      "draft": False,
      ..
    },
  )
  assert_eq(sent[6].body, Some("{}"))
}

///|
async test "permission and concurrency failures are rejected once without refreshing tags" {
  let repo = @moonhub.RepositoryRef::new(owner="team", name="demo")
  let if_match = mutation_test_tag()
  for
    (status, expected) in [
      (401, "unauthorized"),
      (403, "forbidden"),
      (409, "conflict"),
      (412, "conflict"),
    ] {
    let mut sends = 0
    let records : Array[@gh.TraceRecord] = []
    let client = mutation_test_client(
      send=request => {
        @async.pause()
        sends += 1
        assert_eq(request.verb.as_string(), "POST")
        assert_true(
          request.headers.contains(("If-Match", "\"opaque-current-tag\"")),
        )
        @gh.Response::new(
          status~,
          body="{\"version\":1,\"error\":{\"code\":\"forbidden\",\"message\":\"private-server-detail\"}}",
          headers=[("X-Request-Id", "req-denied")],
        )
      },
      trace=record => {
        @async.pause()
        records.push(record)
      },
    )
    let result = client.close_issue(
      repo,
      7,
      if_match~,
      operation_id="conditional-write",
    )
    assert_true(result.outcome is @moonhub.Rejected)
    guard result.value is Err(error) else {
      fail("denied mutation became success")
    }
    assert_eq(error.kind.code(), expected)
    assert_eq(error.status, Some(status))
    assert_eq(error.request_id, Some("req-denied"))
    assert_eq(sends, 1)
    assert_eq(records.length(), 1)
    assert_false(records[0].to_json_line().contains("private-server-detail"))
  }
}

///|
async test "invalid mutation inputs are not sent and do not produce attempt records" {
  let mut sends = 0
  let mut traces = 0
  let client = mutation_test_client(
    send=_ => {
      @async.pause()
      sends += 1
      fail("invalid input reached transport")
    },
    trace=_ => {
      @async.pause()
      traces += 1
    },
  )
  let repo = @moonhub.RepositoryRef::new(owner="team", name="demo")
  let bad_repo = @moonhub.RepositoryRef::new(owner="../team", name="demo")
  let if_match = mutation_test_tag()
  let title = client.create_issue(
    repo,
    title=" \n\t",
    operation_id="invalid-title",
  )
  assert_true(
    title.value is Err(error) && error.kind.code() == "invalid_request",
  )
  assert_true(title.outcome is @moonhub.NotSent)
  assert_true(
    client.create_issue(bad_repo, title="Title", operation_id="invalid-repo").outcome
    is @moonhub.NotSent,
  )
  assert_true(
    client.comment_issue(repo, 0, body="Comment", operation_id="invalid-number").outcome
    is @moonhub.NotSent,
  )
  assert_true(
    client.comment_issue(repo, 7, body="\t\n", operation_id="empty-comment").outcome
    is @moonhub.NotSent,
  )
  assert_true(
    client.create_merge_request(
      repo,
      title="Title",
      source="",
      target="main",
      operation_id="empty-source",
    ).outcome
    is @moonhub.NotSent,
  )
  assert_true(
    client.create_merge_request(
      repo,
      title="Title",
      source="main",
      target="main",
      operation_id="identical-branches",
    ).outcome
    is @moonhub.NotSent,
  )
  assert_true(
    client.merge_merge_request(repo, -1, if_match~, operation_id="invalid-mr").outcome
    is @moonhub.NotSent,
  )
  assert_true(
    client.close_issue(repo, 7, if_match~, operation_id="invalid operation id").outcome
    is @moonhub.NotSent,
  )
  let long_title = StringBuilder()
  for _ in 0..<201 {
    long_title.write_char('x')
  }
  assert_true(
    client.create_issue(
      repo,
      title=long_title.to_string(),
      operation_id="long-title",
    ).outcome
    is @moonhub.NotSent,
  )
  let long_body = StringBuilder()
  for _ in 0..<20001 {
    long_body.write_char('x')
  }
  assert_true(
    client.create_issue(
      repo,
      title="Title",
      description=long_body.to_string(),
      operation_id="long-description",
    ).outcome
    is @moonhub.NotSent,
  )
  assert_true(
    client.comment_merge_request(
      repo,
      3,
      body=long_body.to_string(),
      if_match~,
      operation_id="long-comment",
    ).outcome
    is @moonhub.NotSent,
  )
  assert_eq(sends, 0)
  assert_eq(traces, 0)
}

///|
async test "attempted writes preserve unknown outcome across transport status and decode failures" {
  let repo = @moonhub.RepositoryRef::new(owner="team", name="demo")
  let cases : Array[@gh.Response?] = [
    None,
    Some(@gh.Response::new(status=500, body="private-server-detail")),
    Some(
      @gh.Response::new(status=302, body="", headers=[
        ("Location", "https://other.example"),
      ]),
    ),
    Some(
      @gh.Response::new(status=200, body=mutation_test_issue(), headers=[
        ("ETag", "\"valid\""),
      ]),
    ),
    Some(
      @gh.Response::new(
        status=201,
        body="{\"version\":1,\"data\":{\"private\":\"secret\"}}",
        headers=[("ETag", "\"valid\"")],
      ),
    ),
    Some(@gh.Response::new(status=201, body=mutation_test_issue())),
    Some(
      @gh.Response::new(status=201, body=mutation_test_issue(), headers=[
        ("ETag", "W/\"weak\""),
      ]),
    ),
    Some(
      @gh.Response::new(status=201, body=mutation_test_issue(), headers=[
        ("ETag", "\"one\""),
        ("etag", "\"two\""),
      ]),
    ),
  ]
  for response in cases {
    let mut sends = 0
    let client = mutation_test_client(send=_ => {
      @async.pause()
      sends += 1
      match response {
        Some(response) => response
        None => fail("private-network-secret")
      }
    })
    let result = client.create_issue(
      repo,
      title="Sensitive title",
      operation_id="ambiguous-write",
    )
    assert_true(result.value is Err(_))
    assert_true(result.outcome is @moonhub.Unknown)
    assert_eq(sends, 1)
  }
}

///|
async test "failed trace recording cannot erase applied and accepted mutations" {
  let repo = @moonhub.RepositoryRef::new(owner="team", name="demo")
  let if_match = mutation_test_tag()
  let mut sends = 0
  let client = mutation_test_client(
    send=request => {
      @async.pause()
      sends += 1
      if request.path.has_suffix("/merge") {
        @gh.Response::new(
          status=202,
          body="{\"version\":1,\"data\":{\"number\":3,\"version\":\"5\",\"job_status\":\"running\"}}",
        )
      } else {
        @gh.Response::new(status=201, body=mutation_test_issue(), headers=[
          ("ETag", "\"next\""),
        ])
      }
    },
    trace=_ => {
      @async.pause()
      fail("trace disk unavailable")
    },
  )
  let created = client.create_issue(
    repo,
    title="Title",
    operation_id="trace-create",
  )
  assert_true(created.trace_failed)
  assert_true(created.value is Ok(_))
  assert_true(created.outcome is @moonhub.Applied)
  let queued = client.merge_merge_request(
    repo,
    3,
    if_match~,
    operation_id="trace-merge",
  )
  assert_true(queued.trace_failed)
  assert_true(queued.value is Ok(receipt) && receipt.job_status == "running")
  assert_true(queued.outcome is @moonhub.Accepted)
  assert_eq(sends, 2)
}

///|
async test "merge acknowledgement never turns a completed or malformed job into accepted" {
  let repo = @moonhub.RepositoryRef::new(owner="team", name="demo")
  let if_match = mutation_test_tag()
  for
    body in [
      "{\"version\":1,\"data\":{\"number\":3,\"version\":\"5\",\"job_status\":\"succeeded\"}}",
      "{\"version\":1,\"data\":{\"number\":3,\"version\":\"05\",\"job_status\":\"pending\"}}",
      "{\"version\":1,\"data\":{\"number\":3,\"version\":5,\"job_status\":\"pending\"}}",
    ] {
    let mut sends = 0
    let client = mutation_test_client(send=_ => {
      @async.pause()
      sends += 1
      @gh.Response::new(status=202, body~)
    })
    let result = client.merge_merge_request(
      repo,
      3,
      if_match~,
      operation_id="bad-merge-receipt",
    )
    assert_true(result.outcome is @moonhub.Unknown)
    assert_true(result.value is Err(error) && error.kind.code() == "decode")
    assert_eq(sends, 1)
  }
}

///|
async test "success receipts and status responses must match the requested resource" {
  let repo = @moonhub.RepositoryRef::new(owner="team", name="demo")
  let if_match = mutation_test_tag()
  let mut sends = 0
  let client = mutation_test_client(send=request => {
    @async.pause()
    sends += 1
    let (status, body) = if request.path.has_suffix("/comments") {
      (201, "{\"version\":1,\"data\":{\"number\":99,\"kind\":\"commented\"}}")
    } else if request.path.has_suffix("/merge") {
      (
        202, "{\"version\":1,\"data\":{\"number\":99,\"version\":\"5\",\"job_status\":\"pending\"}}",
      )
    } else {
      // The number is right, but a close request must return a closed Issue.
      (200, mutation_test_issue(status="open"))
    }
    @gh.Response::new(status~, body~, headers=[
      ("ETag", "\"fresh\""),
      ("X-Request-Id", "req-mismatch"),
    ])
  })
  let issue_comment = client.comment_issue(
    repo,
    7,
    body="Comment",
    operation_id="issue-wrong-receipt",
  )
  let mr_comment = client.comment_merge_request(
    repo,
    3,
    body="Comment",
    if_match~,
    operation_id="mr-wrong-receipt",
  )
  let close = client.close_issue(
    repo,
    7,
    if_match~,
    operation_id="wrong-status",
  )
  let merge = client.merge_merge_request(
    repo,
    3,
    if_match~,
    operation_id="wrong-merge",
  )
  assert_true(issue_comment.outcome is @moonhub.Unknown)
  assert_true(mr_comment.outcome is @moonhub.Unknown)
  assert_true(close.outcome is @moonhub.Unknown)
  assert_true(merge.outcome is @moonhub.Unknown)
  guard close.value is Err(error) else { fail("wrong state became success") }
  assert_eq(error.kind.code(), "decode")
  assert_eq(error.status, Some(200))
  assert_eq(error.request_id, Some("req-mismatch"))
  assert_eq(sends, 4)
}

///|
async test "typed mutation tracing omits credentials body and resource text" {
  let records : Array[@gh.TraceRecord] = []
  guard @moonhub.resolve_token(
      base_url="https://moonhub.example",
      explicit="private-token",
    )
    is Ok(Some(token)) else {
    fail("token resolution failed")
  }
  let transport = @gh.Transport::new(origin="https://moonhub.example", send=request => {
    @async.pause()
    assert_true(
      request.headers.contains(("Authorization", "Bearer private-token")),
    )
    assert_true(
      request.body is Some(body) && body.contains("private-description"),
    )
    @gh.Response::new(status=201, body=mutation_test_issue(), headers=[
      ("ETag", "\"next\""),
      ("X-Request-Id", "private-token"),
    ])
  })
  guard @moonhub.Client::new(
      config=@moonhub.ClientConfig::new(base_url="https://moonhub.example"),
      transport~,
      token~,
      trace=record => {
        @async.pause()
        records.push(record)
      },
    )
    is Ok(client) else {
    fail("client construction failed")
  }
  let result = client.create_issue(
    @moonhub.RepositoryRef::new(owner="team", name="demo"),
    title="private-title",
    description="private-description",
    operation_id="safe-id",
  )
  assert_true(result.outcome is @moonhub.Applied)
  assert_true(
    result.value is Ok(issue) && issue.description == "private-description",
  )
  assert_eq(records.length(), 1)
  let line = records[0].to_json_line()
  for
    secret in [
      "private-token", "private-title", "private-description", "opaque-current-tag",
    ] {
    assert_false(line.contains(secret))
  }
  assert_eq(records[0].attempt, 1)
  assert_eq(records[0].status, Some(201))
  assert_true(records[0].request_id is None)
}

///|
async test "creation success must describe the requested initial resource state" {
  let repo = @moonhub.RepositoryRef::new(owner="team", name="demo")
  let mut sends = 0
  let issue_client = mutation_test_client(send=_ => {
    @async.pause()
    sends += 1
    @gh.Response::new(status=201, body=mutation_test_issue(status="closed"), headers=[
      ("ETag", "\"new-issue\""),
      ("X-Request-Id", "req-create-mismatch"),
    ])
  })
  let issue = issue_client.create_issue(
    repo,
    title="Title",
    operation_id="create-closed",
  )
  assert_true(issue.outcome is @moonhub.Unknown)
  assert_true(issue.etag is None)
  guard issue.value is Err(error) else {
    fail("closed issue creation became applied")
  }
  assert_eq(error.status, Some(201))
  assert_eq(error.request_id, Some("req-create-mismatch"))
  for
    (status, source, target, draft) in [
      ("merged", "feature/api", "main", false),
      ("open", "other-source", "main", false),
      ("open", "feature/api", "other-target", false),
      ("open", "feature/api", "main", true),
    ] {
    let client = mutation_test_client(send=_ => {
      @async.pause()
      sends += 1
      let envelope : Json = {
        "version": 1,
        "data": {
          "number": 3,
          "title": "Title",
          "description": "",
          "status": status.to_json(),
          "source": source.to_json(),
          "target": target.to_json(),
          "draft": draft.to_json(),
        },
      }
      @gh.Response::new(status=201, body=envelope.stringify(), headers=[
        ("ETag", "\"new-mr\""),
        ("X-Request-Id", "req-create-mismatch"),
      ])
    })
    let mr = client.create_merge_request(
      repo,
      title="Title",
      source="feature/api",
      target="main",
      operation_id="wrong-created-mr",
    )
    assert_true(mr.outcome is @moonhub.Unknown)
    assert_true(mr.etag is None)
    guard mr.value is Err(error) else {
      fail("different MR creation became applied")
    }
    assert_eq(error.kind.code(), "decode")
    assert_eq(error.status, Some(201))
    assert_eq(error.request_id, Some("req-create-mismatch"))
  }
  assert_eq(sends, 5)
}
