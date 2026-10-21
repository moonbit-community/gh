///|
fn zip_fixture(entries : Array[(String, Bytes)]) -> Bytes raise {
  let archive = @zip.Archive()
  for (name, data) in entries {
    archive.add(name, data, compression=Store)
  }
  @zip.write(archive)
}

///|
test "ZIP adapter preserves nested binary files and explicit directories" {
  let entries = @archive.decode_zip(
    zip_fixture([
      ("nested/", b""),
      ("nested/file.bin", b"\x00\xff\x80"),
      ("empty", b""),
    ]),
  )
  assert_eq(entries.length(), 3)
  assert_true(entries[0].directory())
  assert_eq(entries[1].path(), "nested/file.bin")
  assert_eq(entries[1].data(), b"\x00\xff\x80")
}

///|
test "ZIP adapter rejects traversal absolute paths aliases and file directory conflicts" {
  for
    name in [
      "../escape", "/absolute", "a/../../escape", "a/./b", "a//b", "a\\b", "C:/escape",
      "file:stream", "NUL.txt", "a./file", "a /file", "x\u0000y",
    ] {
    assert_true(
      try {
        ignore(@archive.decode_zip(zip_fixture([(name, b"x")])))
        false
      } catch {
        _ => true
      },
    )
  }
  for
    files in [
      [("a", b"1"), ("a", b"2")],
      [("A", b"1"), ("a", b"2")],
      [("a", b"1"), ("a/b", b"2")],
      [("a/b", b"1"), ("a", b"2")],
    ] {
    assert_true(
      try {
        ignore(@archive.decode_zip(zip_fixture(files)))
        false
      } catch {
        _ => true
      },
    )
  }
}

///|
test "ZIP adapter checks payload CRC and refuses truncated input" {
  let bytes = zip_fixture([("file", b"payload")])
  let corrupted = bytes.to_array()
  // Stored payload starts after the fixed local header and four-byte name.
  corrupted[34] = b'X'
  assert_true(
    try {
      ignore(@archive.decode_zip(Bytes::from_array(corrupted)))
      false
    } catch {
      _ => true
    },
  )
  assert_true(
    try {
      ignore(@archive.decode_zip(bytes[:bytes.length() - 1]))
      false
    } catch {
      _ => true
    },
  )
}

///|
test "ZIP adapter rejects link metadata and enforces inflate and count limits" {
  let bytes = zip_fixture([("link", b"target")])
  let modified = bytes.to_array()
  for index in 0..<(modified.length() - 46) {
    if modified[index] == b'P' &&
      modified[index + 1] == b'K' &&
      modified[index + 2] == b'\x01' &&
      modified[index + 3] == b'\x02' {
      // External attributes contain the Unix file type in the upper 16 bits.
      modified[index + 40] = b'\xff'
      modified[index + 41] = b'\xa1'
      break
    }
  }
  assert_true(
    try {
      ignore(@archive.decode_zip(Bytes::from_array(modified)))
      false
    } catch {
      _ => true
    },
  )
  let archive = @zip.Archive()
  archive.add("large", Bytes::make(10000, b'A'), compression=Deflate)
  let compressed = @zip.write(archive)
  assert_true(
    try {
      ignore(@archive.decode_zip(compressed, max_entry_bytes=100))
      false
    } catch {
      _ => true
    },
  )
  assert_true(
    try {
      ignore(@archive.decode_zip(compressed, max_total_bytes=100))
      false
    } catch {
      _ => true
    },
  )
  assert_true(
    try {
      ignore(
        @archive.decode_zip(
          zip_fixture([("a", b""), ("b", b"")]),
          max_entries=1,
        ),
      )
      false
    } catch {
      _ => true
    },
  )
}
