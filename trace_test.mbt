///|
test "trace removes queries fragments known tokens and arbitrary error messages" {
  let trace = @gh.TraceRecord::new(
    operation_id="op-secret-value",
    attempt=1,
    verb=@gh.HttpMethod::Post,
    path="/api/v1/repos/secret-value/name?token=other-secret#private-fragment",
    status=401,
    duration_ms=7,
    request_id="secret-value",
    error_code="Authorization: Bearer secret-value; body=private-content",
  )
  let line = trace.to_json_line(secrets=["secret-value"])
  let json = @json.parse(line)
  assert_true(
    json
    is {
      "operation_id": "redacted",
      "path": "/api/v1/repos/[redacted]/name",
      "request_id": Null,
      "error_code": "unknown",
      ..
    },
  )
  for
    omitted in [
      "secret-value", "other-secret", "private-fragment", "Authorization", "private-content",
      "body", "headers", "token",
    ] {
    assert_false(line.contains(omitted))
  }
  assert_eq(line.split("\n").count(), 2)
}

///|
test "trace JSONL remains one valid JSON value with hostile metadata" {
  let trace = @gh.TraceRecord::new(
    operation_id="operation\nforged-record",
    attempt=-5,
    verb=@gh.HttpMethod::Get,
    path="/api/v1/quote\"and\\backslash?hidden=true",
    status=999,
    duration_ms=-1,
    request_id="id\r\nAuthorization: secret",
    error_code="transport",
  )
  let json = @json.parse(trace.to_json_line())
  assert_true(
    json
    is {
      "version": 1,
      "operation_id": "redacted",
      "attempt": 1,
      "method": "GET",
      "path": "/api/v1/quote\"and\\backslash",
      "status": Null,
      "duration_ms": Null,
      "request_id": Null,
      "error_code": "transport",
      ..
    },
  )
  assert_eq(trace.to_json_line().split("\n").count(), 2)
}

///|
test "trace rejects URLs encoded paths control characters and oversized IDs" {
  for
    path in [
      "https://user:secret@host/api/v1/meta", "//user:secret@host/api/v1/meta", "/api/v1/s%65cret",
      "/api/v1/meta\nforged",
    ] {
    let trace = @gh.TraceRecord::new(
      operation_id="x".repeat(129),
      attempt=1,
      verb=@gh.HttpMethod::Get,
      path~,
      request_id="x".repeat(129),
    )
    let safe = trace.redacted(secrets=["secret"])
    assert_eq(safe.operation_id, "redacted")
    assert_eq(safe.path, "[redacted]")
    assert_true(safe.request_id is None)
  }
}

///|
test "trace preserves allowed completion metadata and stable encoding" {
  let trace = @gh.TraceRecord::new(
    operation_id="request-2",
    attempt=2,
    verb=@gh.HttpMethod::Patch,
    path="/api/v1/issues/3",
    status=409,
    duration_ms=8,
    request_id="server.123_abc",
    error_code="conflict",
  )
  let line = trace.to_json_line(secrets=[""])
  assert_eq(
    line, "{\"version\":1,\"operation_id\":\"request-2\",\"attempt\":2,\"method\":\"PATCH\",\"path\":\"/api/v1/issues/3\",\"status\":409,\"duration_ms\":8,\"request_id\":\"server.123_abc\",\"error_code\":\"conflict\"}\n",
  )
}
