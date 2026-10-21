///|
test "origins canonicalize credential scope and reject unsupported destinations" {
  for
    (input, expected) in [
      ("HTTPS://GitHub.Example:443/", "https://github.example"),
      ("https://github.example:8443", "https://github.example:8443"),
      ("http://127.0.0.1:080/", "http://127.0.0.1"),
      ("http://api.github.localhost", "http://api.github.localhost"),
    ] {
    match @gh.normalize_origin(input) {
      Ok(actual) => assert_eq(actual, expected)
      Err(_) => fail("valid origin rejected")
    }
  }
  for
    input in [
      "http://remote.example", "https://name:secret@host", "https://host/api", "https://host?token=value",
      "http://api.github.localhost.invalid", "https://host#fragment", "https://host:65536",
      "https://host:", "https://host\\evil", "https://host\n", "https://-host", "https://host..example",
      "https://host//", "file:///tmp/token", "http://[::1]:8080",
    ] {
    assert_true(
      @gh.normalize_origin(input) is Err(@gh.OriginError::InvalidOrigin),
    )
  }
}
