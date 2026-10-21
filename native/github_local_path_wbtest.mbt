///|
test "local paths accept spaces and Windows separators without weakening Git references" {
  for
    path in [
      "a file.txt", "C:\\Users\\Test User\\asset.bin", "\\\\server\\share\\file",
    ] {
    assert_true(valid_local_file_path(path))
    assert_false(valid_local_git_value(path))
  }
  for
    path in [
      "", "bad\u{0}path", "bad\npath", "bad\rpath", "bad\tpath", "bad\u{7f}path",
    ] {
    assert_false(valid_local_file_path(path))
  }
  assert_eq(local_file_basename("directory with spaces/asset.bin"), "asset.bin")
}

///|
#cfg(platform="windows")
test "local basename recognizes Windows drive and UNC separators" {
  assert_eq(local_file_basename("C:\\Users\\Test User\\asset.bin"), "asset.bin")
  assert_eq(local_file_basename("\\\\server\\share\\asset.bin"), "asset.bin")
}

///|
#cfg(not(platform="windows"))
test "local basename preserves POSIX backslashes as filename characters" {
  assert_eq(local_file_basename("directory/a\\b.txt"), "a\\b.txt")
}
