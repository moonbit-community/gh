///|
fn api_options(args : Array[String]) -> @cli.RunOptions raise {
  guard @cli.parse(
      args,
      host_env="https://moonhub.example",
      repo_env="ignored/for-api",
    )
    is Ok(@cli.Run(options)) else {
    fail("API arguments were rejected")
  }
  options
}

///|
test "api plans preserve explicit method, path, repeated headers and input source" {
  let options = api_options(["api", "/meta?feature=opaque%20value", "--json"])
  assert_true(
    options.command is @cli.Api(@gh.Get, "/meta?feature=opaque%20value", []),
  )
  assert_false(options.is_mutation())
  assert_eq(options.max_attempts, 1)
  assert_true(options.body_input is None)
  for verb_text in ["POST", "PUT", "PATCH", "DELETE"] {
    let options = api_options([
      "api", "/repos/team/demo/actions", "-X", verb_text, "-H", "If-Match: \"v1\"",
      "--header", "X-Label: one:two", "--input", "-", "--max-attempts", "1",
    ])
    assert_true(options.is_mutation())
    guard options.command is @cli.Api(verb, path, headers) else {
      fail("expected API plan")
    }
    assert_eq(verb.as_string(), verb_text)
    assert_eq(path, "/repos/team/demo/actions")
    assert_eq(headers, [("If-Match", "\"v1\""), ("X-Label", "one:two")])
    assert_true(options.body_input is Some(@cli.Stdin))
  }
  assert_true(
    api_options(["api", "/custom", "-XPOST", "--input", "payload.json"]).body_input
    is Some(@cli.File("payload.json")),
  )
}

///|
test "api rejects unsafe or ambiguous plans before file and credential loading" {
  for
    args in [
      ["api"],
      ["api", "meta"],
      ["api", "https://other.example/meta"],
      ["api", "//other.example/meta"],
      ["api", "/api/v1/meta"],
      ["api", "/a/../meta"],
      ["api", "/meta#fragment"],
      ["api", "/meta", "--method", "HEAD"],
      ["api", "/meta", "--method", "post"],
      ["api", "/meta", "--input", "file.json"],
      ["api", "/meta", "-XPOST", "--input", ""],
      ["api", "/meta", "--max-attempts", "2"],
      ["api", "/meta", "--repo", "team/demo"],
      ["api", "/meta", "--paginate"],
      ["api", "/meta", "--body", "secret-argv-token"],
      ["api", "/meta", "-H", "broken-header"],
      ["api", "/meta", "-H", "Authorization: secret-argv-token"],
      ["api", "/meta", "-H", "X-HTTP-Method-Override: DELETE"],
      ["api", "/meta", "-H", "Host: other.example"],
      ["api", "/meta", "-H", "Cookie: secret-argv-token"],
      ["api", "/meta", "-H", "Accept: text/html"],
      ["api", "/meta", "-H", "X-Label: line\nbreak"],
      ["api", "/meta", "-H", "X-Label: a", "-H", "x-label: b"],
      ["api", "/meta", "-H", "If-Match: *"],
    ] {
    guard @cli.parse(args, host_env="https://moonhub.example") is Err(message) else {
      fail("invalid API arguments were accepted")
    }
    assert_false(message.contains("secret-argv-token"))
  }
  assert_true(@cli.parse(["api", "--help"]) is Ok(@cli.Help(_)))
}

///|
async test "api JSON output retains the entire response and request metadata" {
  let sent : Array[@gh.Request] = []
  let records : Array[@gh.TraceRecord] = []
  let transport = @gh.Transport::new(origin="https://moonhub.example", send=request => {
    @async.pause()
    sent.push(request)
    @gh.Response::new(
      status=200,
      body="{\"version\":1,\"data\":{\"custom\":true},\"additional\":[1,2]}",
      headers=[("ETag", "\"api-1\""), ("X-Request-Id", "server-api-1")],
    )
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
  let options = api_options([
    "api", "/custom?filter=a%20b", "-H", "X-Label: fixture", "--json",
  ])
  let output = @cli.run(options, client, operation_id="cli-api")
  assert_eq(output.exit_code, 0)
  assert_eq(output.stderr, "")
  assert_eq(sent.length(), 1)
  assert_eq(sent[0].path, "/api/v1/custom?filter=a%20b")
  assert_true(sent[0].headers.contains(("X-Label", "fixture")))
  assert_true(
    @json.parse(output.stdout)
    is {
      "version": 1,
      "data": {
        "version": 1,
        "data": { "custom": true, .. },
        "additional": [1, 2],
        ..
      },
      "status": 200,
      "request_id": "server-api-1",
      "etag": "\"api-1\"",
      "outcome": Null,
      ..
    },
  )
  assert_eq(records.length(), 1)
  assert_eq(records[0].path, "/api/v1/custom")
  assert_eq(records[0].attempt, 1)
  assert_eq(records[0].request_id, Some("server-api-1"))
}

///|
async test "api distinguishes absent, unresolved, empty and JSON null input" {
  let sent : Array[@gh.Request] = []
  let transport = @gh.Transport::new(origin="https://moonhub.example", send=request => {
    @async.pause()
    sent.push(request)
    @gh.Response::new(status=204, body="")
  })
  guard @moonhub.Client::new(
      config=@moonhub.ClientConfig::new(base_url="https://moonhub.example"),
      transport~,
    )
    is Ok(client) else {
    fail("client creation failed")
  }
  let input = api_options(["api", "/custom", "-XPOST", "--input", "-", "--json"])
  let missing = @cli.run(input, client, operation_id="unresolved")
  assert_eq(missing.exit_code, 2)
  assert_true(
    @json.parse(missing.stderr)
    is { "error": { "outcome": "not_sent", .. }, .. },
  )
  let empty = @cli.run(input, client, operation_id="empty", body="")
  assert_eq(empty.exit_code, 2)
  assert_true(sent.is_empty())
  let raw = " \nnull\n"
  let supplied = @cli.run(input, client, operation_id="json-null", body=raw)
  assert_eq(supplied.exit_code, 0)
  assert_eq(sent[0].body, Some(raw))
  assert_true(
    @json.parse(supplied.stdout)
    is { "data": Null, "status": 204, "outcome": "applied", .. },
  )
  let absent = api_options(["api", "/custom", "-XDELETE", "--json"])
  assert_eq(
    @cli.run(absent, client, operation_id="absent", body="ignored").exit_code,
    0,
  )
  assert_eq(sent.length(), 2)
  assert_true(sent[1].body is None)
}

///|
async test "api never retries GET failures and reports unknown write outcomes safely" {
  for verb_text in ["GET", "POST", "PUT", "PATCH", "DELETE"] {
    let sent : Array[Unit] = []
    let transport = @gh.Transport::new(origin="https://moonhub.example", send=_ => {
      @async.pause()
      sent.push(())
      @gh.Response::new(status=503, body="secret-server-body", headers=[
        ("X-Request-Id", "api-failure"),
      ])
    })
    guard @moonhub.Client::new(
        config=@moonhub.ClientConfig::new(base_url="https://moonhub.example"),
        transport~,
      )
      is Ok(client) else {
      fail("client creation failed")
    }
    let options = api_options(["api", "/custom", "-X", verb_text, "--json"])
    let output = @cli.run(options, client, operation_id="api-failure")
    assert_eq(sent.length(), 1)
    assert_eq(output.exit_code, 1)
    assert_eq(output.stdout, "")
    assert_false(output.stderr.contains("secret-server-body"))
    let error = @json.parse(output.stderr)
    assert_true(
      error
      is { "error": { "status": 503, "request_id": "api-failure", .. }, .. },
    )
    if verb_text == "GET" {
      assert_false(output.stderr.contains("outcome"))
    } else {
      assert_true(error is { "error": { "outcome": "unknown", .. }, .. })
    }
  }
}

///|
async test "api human output is JSON with separate acceptance and trace diagnostics" {
  let transport = @gh.Transport::new(origin="https://moonhub.example", send=_ => {
    @async.pause()
    @gh.Response::new(
      status=202,
      body="{\"queued\":true,\"line\":\"\\u001b[31m\"}",
    )
  })
  guard @moonhub.Client::new(
      config=@moonhub.ClientConfig::new(base_url="https://moonhub.example"),
      transport~,
      trace=_ => {
        @async.pause()
        fail("private-trace-path")
      },
    )
    is Ok(client) else {
    fail("client creation failed")
  }
  let options = api_options(["api", "/custom", "-XPOST"])
  let output = @cli.run(options, client, operation_id="api-accepted")
  assert_eq(output.exit_code, 0)
  assert_true(
    @json.parse(output.stdout) is { "queued": true, "line": "\u001b[31m", .. },
  )
  assert_false(output.stdout.contains("\u001b"))
  assert_true(output.stderr.contains("HTTP 202; write outcome: accepted"))
  assert_true(output.stderr.contains("inspect the endpoint for completion"))
  assert_true(output.stderr.contains("trace_failed"))
  assert_false(output.stderr.contains("private-trace-path"))
}
