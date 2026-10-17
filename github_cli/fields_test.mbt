///|
test "@github_cli.build_fields merges nested objects and scalar arrays" {
  let fields = @github_cli.build_fields(
    [
      ("a[x]", Json::string("1")),
      ("a[y]", Json::number(2.0)),
      ("tags[]", Json::string("one")),
      ("tags[]", Json::string("two")),
    ],
    [],
  )
  assert_true(fields is Ok(_))
  assert_eq(fields.unwrap()["a"].stringify(), "{\"x\":\"1\",\"y\":2}")
  assert_eq(fields.unwrap()["tags"].stringify(), "[\"one\",\"two\"]")
}

///|
test "@github_cli.build_fields merges array objects then appends on conflicting leaves" {
  let fields = @github_cli.build_fields(
    [
      ("items[][x]", Json::string("one")),
      ("items[][y]", Json::string("two")),
      ("items[][x]", Json::string("three")),
    ],
    [],
  )
  assert_true(fields is Ok(_))
  assert_eq(
    fields.unwrap()["items"].stringify(),
    "[{\"x\":\"one\",\"y\":\"two\"},{\"x\":\"three\"}]",
  )
}

///|
test "@github_cli.build_fields rejects conflicting object and array shapes" {
  for
    values in [
      [("a", Json::string("one")), ("a", Json::string("two"))],
      [("a", Json::string("one")), ("a[x]", Json::string("two"))],
      [("a[x]", Json::string("one")), ("a", Json::string("two"))],
      [("a[]", Json::string("one")), ("a[x]", Json::string("two"))],
      [("a[x]", Json::string("one")), ("a[]", Json::string("two"))],
    ] {
    assert_true(@github_cli.build_fields(values, []) is Err(_))
  }
}

///|
test "@github_cli.build_fields applies explicit empty arrays and rejects malformed paths" {
  let values = @github_cli.build_fields(
    [("a[x]", Json::string("one")), ("items[]", Json::string("stale"))],
    ["a[children]", "items"],
  )
  assert_true(values is Ok(_))
  assert_eq(values.unwrap()["a"].stringify(), "{\"x\":\"one\",\"children\":[]}")
  assert_eq(values.unwrap()["items"].stringify(), "[]")
  for name in ["", "[a]", "a[", "a[x", "a[x]tail", "a[x][y"] {
    assert_true(
      @github_cli.build_fields([(name, Json::string("x"))], []) is Err(_),
    )
  }
}

///|
test "typed fields preserve Int64 boundaries through @github_cli.build_fields" {
  let values = @github_cli.build_fields(
    [
      ("max", @github_cli.typed_field("9223372036854775807")),
      ("min", @github_cli.typed_field("-9223372036854775808")),
      ("too_big", @github_cli.typed_field("9223372036854775808")),
    ],
    [],
  )
  assert_true(values is Ok(_))
  assert_eq(values.unwrap()["max"].stringify(), "9223372036854775807")
  assert_eq(values.unwrap()["min"].stringify(), "-9223372036854775808")
  assert_eq(values.unwrap()["too_big"].stringify(), "\"9223372036854775808\"")
}
