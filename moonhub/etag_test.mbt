///|
test "entity tags preserve exact opaque values and reject unsafe preconditions" {
  for value in ["\"issue-7-v1\"", "\"a,b\\c\"", "\"\""] {
    guard @moonhub.EntityTag::parse(value) is Ok(tag) else {
      fail("valid strong entity tag rejected")
    }
    assert_eq(tag.value(), value)
  }
  for
    value in [
      "",
      "*",
      "unquoted",
      "W/\"weak\"",
      "\"one\", \"two\"",
      "\"one\"\"two\"",
      " \"tag\"",
      "\"tag\" ",
      "\"space tag\"",
      "\"tab\ttag\"",
      "\"line\r\ntag\"",
      "\"unicode月\"",
      "\"" + String::make(255, 'a') + "\"",
    ] {
    assert_true(@moonhub.EntityTag::parse(value) is Err(_))
  }
}
