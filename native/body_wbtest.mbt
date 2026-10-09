///|
async test "body reader preserves Unicode across chunks and rejects malformed or oversized input" {
  let reader = @io.MemoryReader(writer => {
    writer.write(b"first line\n\xe6")
    writer.write(b"\x9c\x88\n")
  })
  defer reader.close()
  assert_eq(read_body(reader), "first line\n月\n")
  for bytes in [b"\xff", @utf8.encode("x".repeat(80001))] {
    let reader = @io.MemoryReader(writer => writer.write(bytes))
    defer reader.close()
    let rejected = try {
      ignore(read_body(reader))
      false
    } catch {
      _ => true
    }
    assert_true(rejected)
  }
}

///|
async test "body file input is bounded regular UTF-8 and preserves newlines" {
  let directory = @fs.tmpdir(prefix="gh-body-")
  defer @fs.rmdir(directory, recursive=true)
  let path = directory + "/body.txt"
  @fs.write_file(path, "说明\nsecond line\n")
  assert_eq(read_body_file(path), "说明\nsecond line\n")
  for path in [directory, directory + "/missing"] {
    assert_true(
      try {
        ignore(read_body_file(path))
        false
      } catch {
        _ => true
      },
    )
  }
  @fs.write_file(path, "x".repeat(80001))
  assert_true(
    try {
      ignore(read_body_file(path))
      false
    } catch {
      _ => true
    },
  )
}
