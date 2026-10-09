///|
test "pipeline plans preserve Int64 run numbers and require exact preconditions" {
  let host_env = "https://moonhub.example"
  let repo_env = "team/demo"
  guard @cli.parse(
      ["pipeline", "view", "9223372036854775807", "--max-attempts", "1"],
      host_env~,
      repo_env~,
    )
    is Ok(@cli.Run(options)) else {
    fail("valid pipeline view rejected")
  }
  assert_true(options.command is @cli.Pipeline(_, "9223372036854775807"))
  assert_false(options.is_mutation())
  assert_eq(options.max_attempts, 1)
  for action in ["cancel", "rerun"] {
    guard @cli.parse(
        ["pipeline", action, "12", "--if-match", "\"run12\""],
        host_env~,
        repo_env~,
      )
      is Ok(@cli.Run(options)) else {
      fail("valid pipeline control rejected")
    }
    assert_true(options.is_mutation())
  }
  for
    args in [
      ["pipeline", "view", "0"],
      ["pipeline", "view", "01"],
      ["pipeline", "view", "9223372036854775808"],
      ["pipeline", "cancel", "12"],
      ["pipeline", "rerun", "12", "--if-match", "*"],
      ["pipeline", "list", "--max-attempts", "6"],
      ["pipeline", "view", "12", "--max-attempts", "0"],
    ] {
    assert_true(@cli.parse(args, host_env~, repo_env~) is Err(_))
  }
}

///|
test "offline trace plans require no host and combine safe filters" {
  guard @cli.parse(
      [
        "trace", "show", "operation-1", "--trace", "trace.jsonl", "--json", "--request-id",
        "server-2", "--status", "503", "--method", "GET", "--limit", "2",
      ],
      host_env="invalid ambient host",
    )
    is Ok(@cli.Trace(options)) else {
    fail("offline trace plan rejected")
  }
  assert_eq(options.path, "trace.jsonl")
  assert_true(options.json)
  for
    args in [
      ["trace", "list"],
      ["trace", "list", "--trace", "-"],
      ["trace", "show", "--trace", "trace.jsonl"],
      [
        "trace", "show", "one", "--operation-id", "two", "--trace", "trace.jsonl",
      ],
      ["trace", "list", "--trace", "trace.jsonl", "--method", "CONNECT"],
      ["trace", "list", "--trace", "trace.jsonl", "--status", "600"],
      ["trace", "list", "--trace", "trace.jsonl", "--limit", "1001"],
    ] {
    assert_true(@cli.parse(args) is Err(_))
  }
}

///|
test "trace output shows truncation and crash tail without raw fields" {
  let record = @gh.TraceRecord::new(
    operation_id="operation-1",
    attempt=1,
    verb=@gh.Get,
    path="/api/v1/meta?secret=private",
    status=503,
    request_id="server-1",
  )
  let content = record.to_json_line() + record.to_json_line() + "{unfinished"
  let query = @gh.TraceQuery::new(limit=1).unwrap()
  let result = @gh.parse_trace_jsonl(content, query~)
  let output = @cli.trace_output(result, json=true)
  assert_eq(output.exit_code, 0)
  assert_eq(output.stderr, "")
  assert_false(output.stdout.contains("private"))
  assert_true(
    @json.parse(output.stdout)
    is {
      "version": 1,
      "data": [{ "request_id": "server-1", .. }],
      "scan": {
        "scanned": 2,
        "matched": 2,
        "truncated": true,
        "incomplete_tail": true,
        ..
      },
      ..
    },
  )
  let human = @cli.trace_output(result, json=false)
  assert_true(human.stdout.contains("server-1"))
  assert_true(human.stderr.contains("Incomplete final trace record"))
  assert_true(human.stderr.contains("More matching attempts"))
}
