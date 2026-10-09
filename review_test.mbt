///|
test "review trace numeric metadata rejects rounded fractions and underflow" {
  let line = @gh.TraceRecord::new(
    operation_id="precision",
    attempt=1,
    verb=@gh.Get,
    path="/user",
    duration_ms=0,
  ).to_json_line()
  for
    (before, after) in [
      ("\"version\":1", "\"version\":1.0000000000000001"),
      ("\"attempt\":1", "\"attempt\":1.0000000000000001"),
      ("\"duration_ms\":0", "\"duration_ms\":1e-999"),
    ] {
    assert_true(
      @gh.parse_trace_jsonl(line.replace_all(old=before, new=after)) is Err(_),
    )
  }
}

///|
test "review redaction expansion remains readable within trace limits" {
  let record = @gh.TraceRecord::new(
    operation_id="bounded",
    attempt=1,
    verb=@gh.Get,
    path="/" + Array::make(2040, "x").join(""),
  )
  let redacted = record.redacted(secrets=["x"])
  assert_true(redacted.path.length() <= 2048)
  let line = record.to_json_line(secrets=["x"])
  assert_true(@gh.parse_trace_jsonl(line) is Ok(_))
}
