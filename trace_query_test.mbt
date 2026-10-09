///|
fn query_record(operation : String, attempt : Int, status : Int) -> String {
  @gh.TraceRecord::new(
    operation_id=operation,
    attempt~,
    verb=@gh.Get,
    path="/api/v1/repos/alice/demo/issues?page=2",
    status~,
    duration_ms=9007199254740991L,
    request_id="request-\{attempt}",
  ).to_json_line()
}

///|
test "trace queries retain latest matches in file order with AND filters" {
  let content = query_record("other", 1, 200) +
    query_record("operation-1", 1, 503) +
    query_record("operation-1", 2, 200) +
    query_record("operation-1", 3, 200)
  let query = @gh.TraceQuery::new(operation_id="operation-1", limit=2).unwrap()
  let result = @gh.parse_trace_jsonl(content, query~).unwrap()
  assert_eq(result.scanned, 4)
  assert_eq(result.matched, 3)
  assert_true(result.truncated)
  assert_false(result.incomplete_tail)
  assert_eq(result.records.map(record => record.attempt), [2, 3])
  let query = @gh.TraceQuery::new(
    operation_id="operation-1",
    request_id="request-2",
    status=200,
    verb=@gh.Get,
    path_prefix="/api/v1/repos/alice/",
  ).unwrap()
  let result = @gh.parse_trace_jsonl(content, query~).unwrap()
  assert_eq(result.matched, 1)
  assert_true(
    result.to_json()
    is {
      "version": 1,
      "data": [{ "attempt": 2, "duration_ms": 9007199254740991, .. }],
      "scan": {
        "scanned": 4,
        "matched": 1,
        "truncated": false,
        "incomplete_tail": false,
        ..
      },
      ..
    },
  )
}

///|
test "trace query ignores incomplete final append and validates all complete lines" {
  let complete = query_record("operation-1", 1, 200)
  for tail in ["{broken", "{}"] {
    let result = @gh.parse_trace_jsonl(complete + tail).unwrap()
    assert_eq(result.scanned, 1)
    assert_eq(result.records.length(), 1)
    assert_true(result.incomplete_tail)
  }
  for malformed in ["{}\n", "not-json\n", "\n"] {
    let query = @gh.TraceQuery::new(limit=1).unwrap()
    assert_true(
      @gh.parse_trace_jsonl(complete + malformed, query~) is Err(@gh.Decode(..)),
    )
  }
  let empty = @gh.parse_trace_jsonl("").unwrap()
  assert_eq(empty.scanned, 0)
  assert_eq(empty.records.length(), 0)
  assert_false(empty.incomplete_tail)
}

///|
test "trace input drops unknown fields and reapplies metadata redaction" {
  let content =
    #|{"version":1,"operation_id":"secret-token","attempt":1,"method":"POST","path":"/api/v1/secret-token?password=hidden","status":401,"duration_ms":1,"request_id":"id\nforged","error_code":"Authorization: secret-token","body":"private-body","headers":{"Authorization":"Bearer secret-token"}}
  let result = @gh.parse_trace_jsonl(content + "\n", secrets=["secret-token"]).unwrap()
  let output = result.to_json().stringify()
  for
    omitted in [
      "secret-token", "hidden", "private-body", "Authorization", "forged",
    ] {
    assert_false(output.contains(omitted))
  }
  assert_true(
    result.to_json()
    is {
      "data": [
        {
          "operation_id": "redacted",
          "path": "/api/v1/[redacted]",
          "request_id": Null,
          "error_code": "unknown",
          ..
        },
      ],
      ..
    },
  )
}

///|
test "trace query validates integer domains versions and bounded input" {
  let valid = query_record("operation-1", 1, 200)
  for
    (old, new) in [
      ("\"version\":1", "\"version\":2"),
      ("\"attempt\":1", "\"attempt\":1.5"),
      ("\"attempt\":1", "\"attempt\":0"),
      ("\"status\":200", "\"status\":999"),
      ("\"method\":\"GET\"", "\"method\":\"HEAD\""),
      ("\"duration_ms\":9007199254740991", "\"duration_ms\":9007199254740992"),
    ] {
    assert_true(
      @gh.parse_trace_jsonl(valid.replace_all(old~, new~))
      is Err(@gh.Decode(..)),
    )
  }
  assert_true(@gh.parse_trace_jsonl("x".repeat(16385)) is Err(@gh.Decode(..)))
  assert_true(@gh.parse_trace_jsonl("x".repeat(8388609)) is Err(@gh.Decode(..)))
  for limit in [0, 1001] {
    assert_true(@gh.TraceQuery::new(limit~) is Err(@gh.InvalidRequest(..)))
  }
  for value in ["", "id\nforged", "x".repeat(129)] {
    assert_true(
      @gh.TraceQuery::new(operation_id=value) is Err(@gh.InvalidRequest(..)),
    )
    assert_true(
      @gh.TraceQuery::new(request_id=value) is Err(@gh.InvalidRequest(..)),
    )
  }
  for
    path_prefix in [
      "", "https://host/path", "/api?token=x", "/api%2fx", "/api#fragment",
    ] {
    assert_true(
      @gh.TraceQuery::new(path_prefix~) is Err(@gh.InvalidRequest(..)),
    )
  }
  assert_true(@gh.TraceQuery::new(status=99) is Err(@gh.InvalidRequest(..)))
  assert_true(@gh.TraceQuery::new(status=600) is Err(@gh.InvalidRequest(..)))
}
