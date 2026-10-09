///|
test "write plans require explicit fields, body sources, and strong preconditions" {
  let host = "https://moonhub.example"
  let repo = "team/demo"
  guard @cli.parse(
      ["issue", "create", "--title", "A title", "--body", "A body"],
      host_env=host,
      repo_env=repo,
    )
    is Ok(@cli.Run(opts)) else {
    fail("issue creation was rejected")
  }
  assert_true(opts.is_mutation())
  assert_true(opts.command is @cli.CreateIssue(_, "A title"))
  assert_true(opts.body_input is Some(@cli.Literal("A body")))
  guard @cli.parse(
      [
        "pr", "create", "--title", "A title", "--source", "feature", "--target",
        "main", "--draft", "--body-file", "description.md",
      ],
      host_env=host,
      repo_env=repo,
    )
    is Ok(@cli.Run(opts)) else {
    fail("merge request creation was rejected")
  }
  assert_true(
    opts.command
    is @cli.CreateMergeRequest(_, "A title", "feature", "main", true),
  )
  assert_true(opts.body_input is Some(@cli.File("description.md")))
  guard @cli.parse(
      ["pr", "comment", "8", "--body-file", "-", "--if-match", "\"mr-8-v1\""],
      host_env=host,
      repo_env=repo,
    )
    is Ok(@cli.Run(opts)) else {
    fail("stdin comment was rejected")
  }
  assert_true(
    opts.command is @cli.CommentMergeRequest(_, 8, tag) &&
    tag.value() == "\"mr-8-v1\"",
  )
  assert_true(opts.body_input is Some(@cli.Stdin))
  for
    args in [
      ["issue", "create"],
      ["issue", "create", "--title", "  "],
      [
        "issue", "create", "--title", "t", "--body", "body", "--body-file", "body.md",
      ],
      ["issue", "create", "--title", "t", "--body-file", ""],
      ["issue", "comment", "7"],
      ["issue", "comment", "0", "--body", "body"],
      ["issue", "comment", "7", "--body", "\n "],
      ["issue", "close", "7"],
      ["issue", "close", "7", "--if-match", "*"],
      ["issue", "reopen", "7", "--if-match", "W/\"issue-7-v1\""],
      ["issue", "close", "7", "--if-match", "\"a\", \"b\""],
      ["pr", "create", "--title", "t"],
      ["pr", "create", "--title", "t", "--source", "feature"],
      ["pr", "comment", "8", "--body", "body"],
      ["pr", "merge", "8"],
      ["pr", "merge", "8", "--if-match", "secret-token"],
      ["issue", "create", "--title", "t", "--paginate"],
    ] {
    guard @cli.parse(args, host_env=host, repo_env=repo) is Err(message) else {
      fail("invalid write arguments were accepted")
    }
    assert_false(message.contains("secret-token"))
  }
}

///|
async test "all write commands send one POST with exact body and render mutation outcomes" {
  let issue = "{\"number\":7,\"title\":\"Issue\",\"description\":\"Body\",\"status\":\"open\",\"edit_version\":\"2\"}"
  let closed_issue = "{\"number\":7,\"title\":\"Issue\",\"description\":\"Body\",\"status\":\"closed\",\"edit_version\":\"2\"}"
  let mr = "{\"number\":8,\"title\":\"MR\",\"description\":\"Body\",\"source\":\"feature\",\"target\":\"main\",\"draft\":true,\"status\":\"open\",\"version\":\"1\",\"edit_version\":\"1\"}"
  let cases : Array[(Array[String], String, Int, String, String, String?)] = [
    (
      ["issue", "create", "--title", "Issue", "--body", "Body"],
      "/issues",
      201,
      issue,
      "{\"title\":\"Issue\",\"description\":\"Body\"}",
      None,
    ),
    (
      ["issue", "comment", "7", "--body", "Comment"],
      "/issues/7/comments",
      201,
      "{\"number\":7,\"kind\":\"commented\"}",
      "{\"body\":\"Comment\"}",
      None,
    ),
    (
      ["issue", "close", "7", "--if-match", "\"v1\""],
      "/issues/7/close",
      200,
      closed_issue,
      "{}",
      Some("\"v1\""),
    ),
    (
      ["issue", "reopen", "7", "--if-match", "\"v1\""],
      "/issues/7/reopen",
      200,
      issue,
      "{}",
      Some("\"v1\""),
    ),
    (
      [
        "pr", "create", "--title", "MR", "--source", "feature", "--target", "main",
        "--body", "Body", "--draft",
      ],
      "/merge-requests",
      201,
      mr,
      "{\"title\":\"MR\",\"description\":\"Body\",\"source\":\"feature\",\"target\":\"main\",\"draft\":true}",
      None,
    ),
    (
      ["pr", "comment", "8", "--body", "Comment", "--if-match", "\"v1\""],
      "/merge-requests/8/comments",
      201,
      "{\"number\":8,\"kind\":\"commented\"}",
      "{\"body\":\"Comment\"}",
      Some("\"v1\""),
    ),
    (
      ["pr", "merge", "8", "--if-match", "\"v1\""],
      "/merge-requests/8/merge",
      202,
      "{\"number\":8,\"version\":\"1\",\"job_status\":\"pending\"}",
      "{}",
      Some("\"v1\""),
    ),
  ]
  for (args, suffix, status, data, expected_body, expected_tag) in cases {
    let sent : Array[@gh.Request] = []
    let transport = @gh.Transport::new(origin="https://moonhub.example", send=request => {
      @async.pause()
      sent.push(request)
      @gh.Response::new(status~, body="{\"version\":1,\"data\":\{data}}", headers=[
        ("ETag", "\"v2\""),
      ])
    })
    guard @moonhub.Client::new(
        config=@moonhub.ClientConfig::new(base_url="https://moonhub.example"),
        transport~,
      )
      is Ok(client) else {
      fail("client creation failed")
    }
    guard @cli.parse(
        args + ["--json"],
        host_env="https://moonhub.example",
        repo_env="team/demo",
      )
      is Ok(@cli.Run(opts)) else {
      fail("write command parsing failed")
    }
    let output = @cli.run(opts, client, operation_id="cli-write")
    assert_eq(output.exit_code, 0)
    assert_eq(output.stderr, "")
    assert_eq(sent.length(), 1)
    assert_eq(sent[0].verb.as_string(), "POST")
    assert_eq(sent[0].path, "/api/v1/repos/team/demo" + suffix)
    assert_eq(@json.parse(sent[0].body.unwrap()), @json.parse(expected_body))
    let actual_tags = sent[0].headers.filter(pair => {
      pair.0.to_lower() == "if-match"
    })
    match expected_tag {
      Some(tag) => assert_eq(actual_tags, [("If-Match", tag)])
      None => assert_true(actual_tags.is_empty())
    }
    let envelope = @json.parse(output.stdout)
    assert_true(
      envelope is { "version": 1, "pagination": Null, "etag": "\"v2\"", .. },
    )
    if status == 202 {
      assert_true(
        envelope
        is {
          "outcome": "accepted",
          "data": { "job_status": "pending", .. },
          ..
        },
      )
    } else {
      assert_true(envelope is { "outcome": "applied", .. })
    }
  }
}

///|
async test "unresolved bodies never send and supplied stdin body is sent without normalization" {
  let sent : Array[@gh.Request] = []
  let transport = @gh.Transport::new(origin="https://moonhub.example", send=request => {
    @async.pause()
    sent.push(request)
    @gh.Response::new(
      status=201,
      body="{\"version\":1,\"data\":{\"number\":7,\"kind\":\"commented\"}}",
    )
  })
  guard @moonhub.Client::new(
      config=@moonhub.ClientConfig::new(base_url="https://moonhub.example"),
      transport~,
    )
    is Ok(client) else {
    fail("client creation failed")
  }
  guard @cli.parse(
      ["issue", "comment", "7", "--body-file", "-", "--json"],
      host_env="https://moonhub.example",
      repo_env="team/demo",
    )
    is Ok(@cli.Run(opts)) else {
    fail("body plan parsing failed")
  }
  let missing = @cli.run(opts, client, operation_id="missing-input")
  assert_eq(missing.exit_code, 2)
  assert_true(sent.is_empty())
  assert_true(
    @json.parse(missing.stderr)
    is { "error": { "outcome": "not_sent", .. }, .. },
  )
  let completed = @cli.run(
    opts,
    client,
    operation_id="stdin-input",
    body="中文\nsecond line\n",
  )
  assert_eq(completed.exit_code, 0)
  assert_eq(sent.length(), 1)
  assert_true(
    @json.parse(sent[0].body.unwrap())
    is { "body": "中文\nsecond line\n", .. },
  )
}

///|
async test "write errors preserve exit categories and unknown outcome requires inspection" {
  let cases : Array[(Int, Int, String)] = [
    (403, 3, "rejected"),
    (412, 4, "rejected"),
    (503, 1, "unknown"),
  ]
  for (status, exit_code, outcome) in cases {
    let sent : Array[Unit] = []
    let transport = @gh.Transport::new(origin="https://moonhub.example", send=_ => {
      @async.pause()
      sent.push(())
      @gh.Response::new(status~, body="secret-server-body")
    })
    guard @moonhub.Client::new(
        config=@moonhub.ClientConfig::new(base_url="https://moonhub.example"),
        transport~,
      )
      is Ok(client) else {
      fail("client creation failed")
    }
    guard @cli.parse(
        ["issue", "comment", "7", "--body", "private-body", "--json"],
        host_env="https://moonhub.example",
        repo_env="team/demo",
      )
      is Ok(@cli.Run(opts)) else {
      fail("command parsing failed")
    }
    let output = @cli.run(opts, client, operation_id="write-error")
    assert_eq(output.exit_code, exit_code)
    assert_eq(output.stdout, "")
    assert_eq(sent.length(), 1)
    assert_false(output.stderr.contains("private-body"))
    assert_false(output.stderr.contains("secret-server-body"))
    guard @json.parse(output.stderr)
      is { "error": { "outcome": String(actual), .. }, .. } else {
      fail("write outcome missing")
    }
    assert_eq(actual, outcome)
    assert_eq(
      output.stderr.contains("inspect the resource before retrying"),
      outcome == "unknown",
    )
  }
  let unknown = @cli.failure_output(
    @gh.ApiFailure::new(kind=@gh.Transport(message="secret-token")),
    json=false,
    outcome=@moonhub.Unknown,
  )
  assert_eq(unknown.exit_code, 5)
  assert_true(unknown.stderr.contains("write outcome is unknown"))
  assert_false(unknown.stderr.contains("secret-token"))
}

///|
async test "accepted merges and failed traces never claim completed merge or ask to retry" {
  let transport = @gh.Transport::new(origin="https://moonhub.example", send=_ => {
    @async.pause()
    @gh.Response::new(
      status=202,
      body="{\"version\":1,\"data\":{\"number\":8,\"version\":\"3\",\"job_status\":\"pending\"}}",
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
  guard @cli.parse(
      ["pr", "merge", "8", "--if-match", "\"v1\""],
      host_env="https://moonhub.example",
      repo_env="team/demo",
    )
    is Ok(@cli.Run(opts)) else {
    fail("command parsing failed")
  }
  let output = @cli.run(opts, client, operation_id="accepted-merge")
  assert_eq(output.exit_code, 0)
  assert_true(output.stdout.contains("merge accepted (pending)"))
  assert_true(output.stdout.contains("inspect pr view"))
  assert_false(output.stdout.contains("merged"))
  assert_true(output.stderr.contains("trace_failed"))
  assert_false(output.stderr.contains("private-trace-path"))
  assert_false(output.stderr.contains("retry"))
}
