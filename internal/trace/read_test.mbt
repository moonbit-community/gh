///|
async test "trace reader returns bounded metadata and recognizes interrupted append" {
  let directory = @fs.tmpdir(prefix="moonhub-gh-trace-read-")
  defer @fs.rmdir(directory, recursive=true)
  let path = "\{directory}/attempts.jsonl"
  let record = @gh.TraceRecord::new(
    operation_id="operation-1",
    attempt=1,
    verb=@gh.Get,
    path="/api/v1/meta?private=secret",
    status=200,
  )
  @trace.append(path, record)
  @fs.write_file(path, "{interrupted", append=true, create_mode=OpenOrCreate)
  let result = @trace.read(path).unwrap()
  assert_eq(result.scanned, 1)
  assert_eq(result.matched, 1)
  assert_true(result.incomplete_tail)
  assert_eq(result.records[0].path, "/api/v1/meta")
}

///|
async test "trace reader rejects symlinks directories missing and invalid UTF8 files" {
  let directory = @fs.tmpdir(prefix="moonhub-gh-trace-read-")
  defer @fs.rmdir(directory, recursive=true)
  let target = "\{directory}/target.jsonl"
  @fs.write_file(target, "")
  let link = "\{directory}/link.jsonl"
  @fs.symlink(target~, link)
  let invalid = "\{directory}/invalid.jsonl"
  @fs.write_file(invalid, b"\xff")
  for path in ["", "-", directory, link, "\{directory}/missing", invalid] {
    assert_true(@trace.read(path) is Err(@gh.InvalidRequest(..)))
  }
  let malformed = "\{directory}/malformed.jsonl"
  @fs.write_file(malformed, "{\n")
  assert_true(@trace.read(malformed) is Err(@gh.Decode(..)))
}

///|
async test "trace reader rejects files beyond byte limit before parsing" {
  let directory = @fs.tmpdir(prefix="moonhub-gh-trace-read-")
  defer @fs.rmdir(directory, recursive=true)
  let path = "\{directory}/oversized.jsonl"
  @fs.write_file(path, "x".repeat(8388609))
  assert_true(@trace.read(path) is Err(@gh.InvalidRequest(..)))
}
