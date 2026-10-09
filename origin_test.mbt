///|
test "origins canonicalize credential scope and reject unsupported destinations" {
  for
    (input, expected) in [
      ("HTTPS://MoonHub.Example:443/", "https://moonhub.example"),
      ("https://moonhub.example:8443", "https://moonhub.example:8443"),
      ("http://127.0.0.1:080/", "http://127.0.0.1"),
    ] {
    match @gh.normalize_origin(input) {
      Ok(actual) => assert_eq(actual, expected)
      Err(_) => fail("valid origin rejected")
    }
  }
  for
    input in [
      "http://remote.example", "https://name:secret@host", "https://host/api", "https://host?token=value",
      "https://host#fragment", "https://host:65536", "https://host:", "https://host\\evil",
      "https://host\n", "https://-host", "https://host..example", "https://host//",
      "file:///tmp/token", "http://[::1]:8080",
    ] {
    assert_true(@gh.normalize_origin(input) is Err(_))
  }
}

///|
test "API paths cannot change origin or traverse API prefix" {
  assert_true(
    @gh.valid_request_path("/repos/team/demo/issues?page=2&q=hello%20world"),
  )
  for
    path in [
      "https://evil/x", "//evil/x", "/../user", "/a/./b", "/%2e%2E/user", "/a%2fb",
      "/a%5Cb", "/%252e/user", "/a#fragment", "/a\r\nb", "/a\\b", "/bad%", "/bad%ZZ",
      "/bad name",
    ] {
    assert_false(@gh.valid_request_path(path))
  }
}
