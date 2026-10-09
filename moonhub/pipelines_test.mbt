///|
fn pipeline_test_data(
  number? : String = "42",
  state? : String = "running",
  conclusion? : String,
) -> Json {
  {
    "number": number.to_json(),
    "workflow_path": ".github/workflows/build.yml",
    "workflow_name": "Build",
    "source_branch": "main",
    "commit_sha": "0123456789abcdef0123456789abcdef01234567",
    "state": state.to_json(),
    "conclusion": match conclusion {
      Some(value) => value.to_json()
      None => Json::null()
    },
    "created_at": "2026-10-09 00:00:00",
  }
}

///|
fn pipeline_test_body(
  number? : String = "42",
  state? : String = "running",
  conclusion? : String,
) -> String {
  let envelope : Json = {
    "version": 1,
    "data": pipeline_test_data(number~, state~, conclusion?),
  }
  envelope.stringify()
}

///|
test "pipeline numbers preserve Int64 identity and reject alternate or unsafe spellings" {
  for number in ["1", "42", "9007199254740993", "9223372036854775807"] {
    assert_true(
      @moonhub.parse_pipeline_number(number) is Ok(actual) && actual == number,
    )
  }
  for
    number in [
      "", "0", "01", "+1", "-1", "1.0", " 1", "1 ", "1/../2", "１", "9223372036854775808",
      "10000000000000000000",
    ] {
    assert_true(@moonhub.parse_pipeline_number(number) is Err(_))
  }
  let large : @moonhub.Pipeline = @json.from_json(
    pipeline_test_data(number="9007199254740993"),
  )
  assert_eq(large.number, "9007199254740993")
  assert_true(
    large.to_json()
    is { "number": String("9007199254740993"), "conclusion": Null, .. },
  )
}

///|
test "pipeline lifecycle is separate from conclusion and unknown metadata stays forward compatible" {
  for state in ["queued", "running"] {
    let run : @moonhub.Pipeline = @json.from_json(pipeline_test_data(state~))
    assert_eq(run.state, state)
    assert_true(run.conclusion is None)
  }
  for conclusion in ["success", "failure", "cancelled", "timed_out", "lost"] {
    let run : @moonhub.Pipeline = @json.from_json(
      pipeline_test_data(state="completed", conclusion~),
    )
    assert_eq(run.conclusion, Some(conclusion))
  }
  for
    (key, value) in [
      ("number", (42 : Json)),
      ("number", ("01" : Json)),
      ("number", ("9223372036854775808" : Json)),
      ("state", ("success" : Json)),
      ("state", ("completed" : Json)),
      ("conclusion", ("success" : Json)),
      ("commit_sha", ("short-sha" : Json)),
      ("commit_sha", ("0123456789ABCDEF0123456789ABCDEF01234567" : Json)),
    ] {
    guard pipeline_test_data() is Object(fields) else {
      fail("expected fixture object")
    }
    fields[key] = value
    let rejected = try {
      let _ : @moonhub.Pipeline = @json.from_json(Json::object(fields))
      false
    } catch {
      _ => true
    }
    assert_true(rejected)
  }
  guard pipeline_test_data() is Object(fields) else {
    fail("expected fixture object")
  }
  fields["future_metadata"] = { "ignored": true }
  let compatible : @moonhub.Pipeline = @json.from_json(Json::object(fields))
  assert_eq(compatible.number, "42")
  let skipped_rejected = try {
    let _ : @moonhub.Pipeline = @json.from_json(
      pipeline_test_data(state="completed", conclusion="skipped"),
    )
    false
  } catch {
    _ => true
  }
  assert_true(skipped_rejected)
}

///|
async test "pipeline list paginates and view retains the opaque resource validator" {
  let requests : Array[@gh.Request] = []
  let records : Array[@gh.TraceRecord] = []
  let client = mutation_test_client(
    send=request => {
      @async.pause()
      requests.push(request)
      assert_true(request.verb is @gh.Get)
      let (data, headers) = match request.path {
        "/api/v1/repos/team/demo/pipelines?page=1&per_page=1" =>
          (
            Json::array([pipeline_test_data()]),
            [("Link", "<?page=2&per_page=1>; rel=\"next\"")],
          )
        "/api/v1/repos/team/demo/pipelines?page=2&per_page=1" =>
          (
            Json::array([
              pipeline_test_data(
                number="41",
                state="completed",
                conclusion="success",
              ),
            ]),
            [],
          )
        "/api/v1/repos/team/demo/pipelines/42" =>
          (pipeline_test_data(), [("ETag", "\"pipeline-current\"")])
        _ => fail("unexpected pipeline read")
      }
      let envelope : Json = { "version": 1, "data": data }
      @gh.Response::new(status=200, body=envelope.stringify(), headers~)
    },
    trace=record => {
      @async.pause()
      records.push(record)
    },
  )
  let repo = @moonhub.RepositoryRef::new(owner="team", name="demo")
  let listed = client.pipelines(
    repo,
    per_page=1,
    paginate=true,
    operation_id="pipeline-list",
  )
  assert_true(
    listed.value is Ok(runs) &&
    runs.length() == 2 &&
    runs[0].number == "42" &&
    runs[1].conclusion == Some("success"),
  )
  assert_eq(listed.pages, 2)
  assert_true(listed.etag is None)
  let viewed = client.pipeline(repo, "42", operation_id="pipeline-view")
  assert_true(viewed.value is Ok(run) && run.state == "running")
  assert_true(viewed.etag is Some(tag) && tag.value() == "\"pipeline-current\"")
  assert_eq(requests.length(), 3)
  assert_eq(records[0].operation_id, records[1].operation_id)
  assert_eq(records[0].attempt, 1)
  assert_eq(records[1].attempt, 2)
}

///|
async test "pipeline cancellation acknowledges a request and rerun creates a new queued snapshot" {
  let requests : Array[@gh.Request] = []
  let client = mutation_test_client(send=request => {
    @async.pause()
    requests.push(request)
    assert_true(request.verb is @gh.Post)
    assert_eq(request.body, Some("{}"))
    assert_true(
      request.headers.contains(("If-Match", "\"opaque-current-tag\"")),
    )
    match request.path {
      "/api/v1/repos/team/demo/pipelines/42/cancel" =>
        @gh.Response::new(
          status=202,
          body="{\"version\":1,\"data\":{\"number\":\"42\",\"kind\":\"cancel_requested\"}}",
        )
      "/api/v1/repos/team/demo/pipelines/41/rerun" =>
        @gh.Response::new(
          status=201,
          body=pipeline_test_body(number="43", state="queued"),
          headers=[("ETag", "\"pipeline-new\"")],
        )
      _ => fail("unexpected pipeline write")
    }
  })
  let repo = @moonhub.RepositoryRef::new(owner="team", name="demo")
  let if_match = mutation_test_tag()
  let cancelled = client.cancel_pipeline(
    repo,
    "42",
    if_match~,
    operation_id="cancel-run",
  )
  assert_true(cancelled.outcome is @moonhub.Accepted)
  assert_true(
    cancelled.value is Ok(receipt) &&
    receipt.kind == "cancel_requested" &&
    receipt.number == "42",
  )
  let rerun = client.rerun_pipeline(
    repo,
    "41",
    if_match~,
    operation_id="rerun-run",
  )
  assert_true(rerun.outcome is @moonhub.Applied)
  assert_true(
    rerun.value is Ok(run) &&
    run.number == "43" &&
    run.state == "queued" &&
    run.conclusion is None,
  )
  assert_true(rerun.etag is Some(tag) && tag.value() == "\"pipeline-new\"")
  assert_eq(requests.length(), 2)
}

///|
async test "pipeline mutation errors preserve ambiguity and never retry or refresh a precondition" {
  let repo = @moonhub.RepositoryRef::new(owner="team", name="demo")
  let if_match = mutation_test_tag()
  for
    response in [
      None,
      Some(@gh.Response::new(status=401, body="private detail")),
      Some(@gh.Response::new(status=403, body="private detail")),
      Some(@gh.Response::new(status=409, body="private detail")),
      Some(@gh.Response::new(status=412, body="private detail")),
      Some(@gh.Response::new(status=500, body="private detail")),
      Some(
        @gh.Response::new(
          status=202,
          body="{\"version\":1,\"data\":{\"number\":\"99\",\"kind\":\"cancel_requested\"}}",
        ),
      ),
      Some(
        @gh.Response::new(
          status=202,
          body="{\"version\":1,\"data\":{\"number\":\"42\",\"kind\":\"cancelled\"}}",
        ),
      ),
    ] {
    let mut sends = 0
    let client = mutation_test_client(send=_ => {
      @async.pause()
      sends += 1
      match response {
        None => fail("lost response")
        Some(response) => response
      }
    })
    let result = client.cancel_pipeline(
      repo,
      "42",
      if_match~,
      operation_id="cancel-failure",
    )
    assert_true(result.value is Err(_))
    assert_eq(
      result.outcome.as_string(),
      if response is Some(response) &&
        response.status >= 400 &&
        response.status < 500 {
        "rejected"
      } else {
        "unknown"
      },
    )
    assert_eq(sends, 1)
  }
  for
    (number, state, headers) in [
      ("41", "queued", [("ETag", "\"new\"")]),
      ("43", "running", [("ETag", "\"new\"")]),
      ("43", "queued", []),
    ] {
    let mut sends = 0
    let client = mutation_test_client(send=_ => {
      @async.pause()
      sends += 1
      @gh.Response::new(
        status=201,
        body=pipeline_test_body(number~, state~),
        headers~,
      )
    })
    let result = client.rerun_pipeline(
      repo,
      "41",
      if_match~,
      operation_id="rerun-failure",
    )
    assert_true(result.value is Err(_))
    assert_true(result.outcome is @moonhub.Unknown)
    assert_eq(sends, 1)
  }
}

///|
async test "pipeline invalid identifiers are not sent and mismatched view is rejected" {
  let mut sends = 0
  let client = mutation_test_client(send=_ => {
    @async.pause()
    sends += 1
    @gh.Response::new(status=200, body=pipeline_test_body(number="99"))
  })
  let repo = @moonhub.RepositoryRef::new(owner="team", name="demo")
  let if_match = mutation_test_tag()
  assert_true(
    client.pipeline(repo, "0", operation_id="invalid-read").value is Err(_),
  )
  assert_true(
    client.cancel_pipeline(repo, "01", if_match~, operation_id="invalid-cancel").outcome
    is @moonhub.NotSent,
  )
  assert_true(
    client.rerun_pipeline(
      repo,
      "9223372036854775808",
      if_match~,
      operation_id="invalid-rerun",
    ).outcome
    is @moonhub.NotSent,
  )
  assert_true(
    client.pipelines(
      @moonhub.RepositoryRef::new(owner="../team", name="demo"),
      operation_id="invalid-list",
    ).value
    is Err(_),
  )
  assert_eq(sends, 0)
  assert_true(
    client.pipeline(repo, "42", operation_id="mismatched-view").value
    is Err(error) &&
    error.kind.code() == "decode",
  )
  assert_eq(sends, 1)
}
