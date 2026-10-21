///|
test "run download retains repeated and attached name and pattern flags" {
  guard @github_cli.parse([
      "run", "download", "123", "-n", "one,two", "-nthree", "--pattern=a?", "-p[bc]*",
      "-D", "out",
    ])
    is @github_cli.Business(options) else {
    fail("parse")
  }
  guard @github_cli.parse_run_download(options) is Ok(parsed) else {
    fail("download parse")
  }
  assert_eq(parsed.names, ["one,two", "three"])
  assert_eq(parsed.patterns, ["a?", "[bc]*"])
  assert_eq(parsed.directory, "out")
  assert_eq(parsed.run_id, Some("123"))
  assert_true(parsed.isolated())
  assert_true(parsed.matches("one,two"))
  assert_true(parsed.matches("a你"))
  assert_false(parsed.matches("a/"))
}

///|
test "download name patterns handle ranges escapes and malformed expressions" {
  for
    (name, pattern, expected) in [
      ("A", "[^a-z]", true),
      ("z", "[a-z]", true),
      ("z", "[z-a]", false),
      ("x", "[!a-z]", true),
      ("a/b", "*", false),
      ("a?b", "a\\?b", true),
      ("abc", "a*c", true),
      ("abc", "[", false),
      ("abc", "[a-]", false),
      ("abc", "a\\", false),
      ("😄", "?", true),
    ] {
    assert_eq(@github_cli.download_name_matches(name, pattern), expected)
  }
}
