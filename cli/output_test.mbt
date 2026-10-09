///|
test "exit policy and JSON errors exclude untrusted messages" {
  let cases : Array[(@gh.ApiError, Int?, Int)] = [
    (@gh.InvalidRequest(message="secret-server-body"), None, 2),
    (@gh.InvalidRequest(message="secret-server-body"), Some(422), 1),
    (@gh.Unauthorized, Some(401), 3),
    (@gh.Forbidden, Some(403), 3),
    (@gh.NotFound, Some(404), 1),
    (@gh.Conflict(message="secret-server-body"), Some(412), 4),
    (@gh.Transport(message="secret-server-body"), None, 5),
    (@gh.Decode(message="secret-server-body"), Some(200), 1),
    (@gh.Server(status=503, message="secret-server-body"), Some(503), 1),
    (@gh.RateLimited, Some(429), 1),
    (@gh.UnexpectedStatus(status=302), Some(302), 1),
  ]
  for (kind, status, exit_code) in cases {
    let output = @cli.failure_output(
      @gh.ApiFailure::new(kind~, status?, request_id="request-42"),
      json=true,
    )
    assert_eq(output.exit_code, exit_code)
    assert_eq(output.stdout, "")
    assert_false(output.stderr.contains("secret-server-body"))
    let data = @json.parse(output.stderr)
    assert_true(
      data is { "version": 1, "error": { "request_id": "request-42", .. }, .. },
    )
  }
  let invalid = @cli.argument_error(
    "invalid command or arguments; run gh --help",
    json=true,
  )
  assert_eq(invalid.exit_code, 2)
  assert_eq(invalid.stdout, "")
  assert_true(
    @json.parse(invalid.stderr)
    is { "error": { "status": Null, "request_id": Null, .. }, .. },
  )
}

///|
async test "all read commands dispatch to the SDK and produce stable JSON envelopes" {
  let cases : Array[(Array[String], String, String)] = [
    (
      ["meta"],
      "/api/v1/meta",
      "{\"api_version\":1,\"server_version\":\"0.1\",\"capabilities\":[\"issues\"]}",
    ),
    (
      ["auth", "status"],
      "/api/v1/user",
      "{\"id\":\"9007199254740993\",\"name_key\":\"winter\",\"display_name\":\"Winter\",\"is_site_admin\":false}",
    ),
    (["repo", "list"], "/api/v1/repos?page=1&per_page=30", "[]"),
    (
      ["repo", "view"],
      "/api/v1/repos/team/demo",
      "{\"owner\":\"team\",\"name\":\"demo\",\"visibility\":\"private\"}",
    ),
    (
      ["issue", "list"],
      "/api/v1/repos/team/demo/issues?page=1&per_page=30",
      "[]",
    ),
    (
      ["issue", "view", "7"],
      "/api/v1/repos/team/demo/issues/7",
      "{\"number\":7,\"title\":\"Issue\",\"description\":\"Body\",\"status\":\"open\"}",
    ),
    (
      ["pr", "list"],
      "/api/v1/repos/team/demo/merge-requests?page=1&per_page=30",
      "[]",
    ),
    (
      ["pr", "view", "8"],
      "/api/v1/repos/team/demo/merge-requests/8",
      "{\"number\":8,\"title\":\"MR\",\"description\":\"Body\",\"source\":\"feature\",\"target\":\"main\",\"draft\":false,\"status\":\"open\"}",
    ),
  ]
  for (args, path, data) in cases {
    let sent : Array[String] = []
    let transport = @gh.Transport::new(origin="https://moonhub.example", send=request => {
      @async.pause()
      sent.push(request.path)
      assert_eq(request.verb.as_string(), "GET")
      @gh.Response::new(status=200, body="{\"version\":1,\"data\":\{data}}")
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
      fail("command parsing failed")
    }
    let output = @cli.run(opts, client, operation_id="cli-command")
    assert_eq(output.exit_code, 0)
    assert_eq(output.stderr, "")
    assert_eq(sent, [path])
    let parsed = @json.parse(output.stdout)
    assert_true(parsed is { "version": 1, "data": _, "pagination": _, .. })
    if args.contains("list") {
      assert_true(
        parsed
        is { "data": [], "pagination": { "pages": 1, "next": Null, .. }, .. },
      )
    } else {
      assert_true(parsed is { "pagination": Null, .. })
    }
    assert_true(output.stdout.has_suffix("\n"))
    assert_false(output.stdout.has_suffix("\n\n"))
  }
}

///|
async test "human summaries sanitize terminal content and trace warnings keep success" {
  let transport = @gh.Transport::new(origin="https://moonhub.example", send=_ => {
    @async.pause()
    @gh.Response::new(
      status=200,
      body="{\"version\":1,\"data\":[{\"number\":1,\"title\":\"line\\n\\u001b[31mred\",\"description\":\"hidden-body\",\"status\":\"open\"}]}",
    )
  })
  guard @moonhub.Client::new(
      config=@moonhub.ClientConfig::new(base_url="https://moonhub.example"),
      transport~,
      trace=_ => {
        @async.pause()
        fail("secret-local-path")
      },
    )
    is Ok(client) else {
    fail("client creation failed")
  }
  guard @cli.parse(
      ["issue", "list"],
      host_env="https://moonhub.example",
      repo_env="team/demo",
    )
    is Ok(@cli.Run(opts)) else {
    fail("command parsing failed")
  }
  let output = @cli.run(opts, client, operation_id="cli-warning")
  assert_eq(output.exit_code, 0)
  assert_eq(output.stdout, "#1\topen\tline  [31mred\n")
  assert_true(output.stderr.contains("trace_failed"))
  assert_false(output.stderr.contains("secret-local-path"))
  assert_false(output.stdout.contains("hidden-body"))
}
