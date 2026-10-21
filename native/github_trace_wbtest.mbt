///|
async test "trace file appends redacted events without truncating prior evidence" {
  let directory = @fs.tmpdir(prefix="gh-trace-append-")
  defer @fs.rmdir(directory, recursive=true)
  let path = directory + "/events.jsonl"
  let secret = "synthetic-private-trace-token"
  for index in 1..<4 {
    append_github_trace(
      path,
      @github.TraceRecord::new(
        host="api.github.com",
        operation_name="api",
        operation_id=index.to_string(),
        verb="GET",
        path="/repos/acme/widgets?access_token=" + secret,
        attempt=index,
        status=200,
      ),
      [secret],
    )
  }
  let bytes = @fs.read_file(path).text()
  let lines = bytes.trim_end().split("\n").to_array()
  assert_eq(lines.length(), 3)
  for index in 0..<3 {
    let value = @json.parse(lines[index])
    guard value is { "operation_id": String(id), "path": String(path), .. } else {
      fail("trace event")
    }
    assert_eq(id, (index + 1).to_string())
    assert_eq(path, "/repos/acme/widgets")
  }
  assert_false(bytes.contains(secret))
  assert_false(bytes.contains("access_token"))
}
