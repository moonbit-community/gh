///|
test "release archive MIME filenames handle quotes extended unicode and reject ambiguity" {
  assert_eq(
    release_archive_filename("attachment; filename=\"a;b.zip\""),
    Ok("a;b.zip"),
  )
  assert_eq(
    release_archive_filename(
      "attachment; filename=other.zip; filename*=UTF-8''%E4%B8%AD.zip",
    ),
    Ok("中.zip"),
  )
  assert_eq(
    release_archive_filename("attachment; filename=\"/parent/archive.zip\""),
    Ok("archive.zip"),
  )
  assert_true(
    release_archive_filename("attachment; filename=a.zip; filename=b.zip")
    is Err(_),
  )
  assert_true(
    release_archive_filename("attachment; filename=\"unterminated") is Err(_),
  )
  assert_true(release_archive_filename("attachment; filename=\"..\"") is Err(_))
  assert_true(release_archive_filename("") is Err(_))
}

///|
test "release stdout refuses escaped text before output while explicit override preserves bytes" {
  let bytes = b"prefix\x1b[31mred"
  let result = release_download_stdout(bytes, false)
  assert_eq(result.exit_code(), 1)
  assert_eq(result.stdout_bytes(), b"")
  assert_eq(release_download_stdout(bytes, true).stdout_bytes(), bytes)
}
