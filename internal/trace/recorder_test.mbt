///|
async test "trace file appends sanitized JSONL without truncating prior records" {
  let directory = @fs.tmpdir(prefix="moonhub-gh-trace-")
  defer @fs.rmdir(directory, recursive=true)
  let path = "\{directory}/attempts.jsonl"
  let first = @gh.TraceRecord::new(
    operation_id="operation-1",
    attempt=1,
    verb=@gh.HttpMethod::Get,
    path="/api/v1/meta?token=secret-token",
    status=200,
  )
  @trace.append(path, first, secrets=["secret-token"])
  let second = @gh.TraceRecord::new(
    operation_id="operation-2",
    attempt=1,
    verb=@gh.HttpMethod::Post,
    path="/api/v1/repos/secret-token/issues",
    error_code="transport",
  )
  @trace.append(path, second, secrets=["secret-token"])
  let content = @fs.read_file(path).text()
  let lines = content.split("\n").collect()
  assert_eq(lines.length(), 3)
  assert_eq(lines[2], "")
  assert_true(
    @json.parse(lines[0])
    is {
      "operation_id": "operation-1",
      "status": 200,
      "path": "/api/v1/meta",
      ..
    },
  )
  assert_true(
    @json.parse(lines[1])
    is {
      "operation_id": "operation-2",
      "error_code": "transport",
      "path": "/api/v1/repos/[redacted]/issues",
      ..
    },
  )
  assert_false(content.contains("secret-token"))
}

///|
async test "trace refuses stdout shorthand directories and symlinks" {
  let directory = @fs.tmpdir(prefix="moonhub-gh-trace-")
  defer @fs.rmdir(directory, recursive=true)
  let record = @gh.TraceRecord::new(
    operation_id="operation-1",
    attempt=1,
    verb=@gh.HttpMethod::Get,
    path="/api/v1/meta",
  )
  let target = "\{directory}/target.jsonl"
  @fs.write_file(target, "existing\n", permission=0o600)
  let link = "\{directory}/link.jsonl"
  @fs.symlink(target~, link)
  let dangling = "\{directory}/dangling.jsonl"
  @fs.symlink(target="\{directory}/absent.jsonl", dangling)
  for path in ["", "-", directory, link, dangling] {
    try @trace.append(path, record) catch {
      _ => ()
    } noraise {
      _ => fail("Unsafe trace destination was accepted")
    }
  }
  assert_eq(@fs.read_file(target).text(), "existing\n")
}
