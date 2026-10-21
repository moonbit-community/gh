///|
test "cache identifiers use signed decimal int64 and preserve oversized numeric keys" {
  for
    (input, expected) in [
      ("+00012", Some("12")),
      ("-0012", Some("-12")),
      ("0", Some("0")),
      ("9223372036854775807", Some("9223372036854775807")),
      ("-9223372036854775808", Some("-9223372036854775808")),
      ("9223372036854775808", None),
      ("-9223372036854775809", None),
      ("0x12", None),
      ("1_2", None),
      ("12 ", None),
      ("", None),
      ("+", None),
    ] {
    assert_eq(@github_cli.cache_identifier_id(input), expected)
  }
}
