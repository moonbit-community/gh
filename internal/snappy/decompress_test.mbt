///|
test "Snappy literal and overlapping copy records decode exact bytes" {
  assert_eq(@snappy.decompress(b"\x05\x10hello"), b"hello")
  assert_eq(@snappy.decompress(b"\x08\x00a\x0d\x01"), b"aaaaaaaa")
  assert_eq(@snappy.decompress(b"\x06\x04ab\x0e\x02\x00"), b"ababab")
  assert_eq(@snappy.decompress(b"\x06\x04ab\x0f\x02\x00\x00\x00"), b"ababab")
  assert_eq(@snappy.decompress(b"\x00"), b"")
}

///|
test "Snappy bounds truncation overflow invalid offset and trailing data reject" {
  for
    input in [
      b"", b"\x80", b"\xff\xff\xff\xff\x7f", b"\x05\x10hell", b"\x08\x00a\x0d\x00",
      b"\x01\xfc\xff\xff\xff\xff", b"\x00\x00", b"\x01\x00a\x00b",
    ] {
    assert_true(
      try {
        ignore(@snappy.decompress(input))
        false
      } catch {
        _ => true
      },
    )
  }
  assert_true(
    try {
      ignore(@snappy.decompress(b"\x05\x10hello", max_output_bytes=4))
      false
    } catch {
      _ => true
    },
  )
}
