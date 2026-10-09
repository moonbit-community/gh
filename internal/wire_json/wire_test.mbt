///|
test "review exact bounded integers preserve equivalent decimal spellings" {
  for
    (text, expected) in [
      ("0", 0L),
      ("-0.0", 0L),
      ("0e-999999999999999999999", 0L),
      ("1", 1L),
      ("1.0", 1L),
      ("10e-1", 1L),
      ("0.1e+1", 1L),
      ("1000e-2", 10L),
      ("1E3", 1000L),
      ("2147483647", 2147483647L),
      ("9007199254740991", 9007199254740991L),
      ("0." + Array::make(30, "0").join("") + "1e31", 1L),
    ] {
    assert_eq(
      @wire_json.integer(
        @wire_json.parse(text),
        minimum=0,
        maximum=9007199254740991,
      ),
      Some(expected),
    )
  }
  for
    text in [
      "-1", "1.5", "1.0000000000000001", "2147483647.00000001", "1e-999", "9007199254740991.1",
      "9007199254740992", "1e999", "\"1\"",
    ] {
    assert_eq(
      @wire_json.integer(
        @wire_json.parse(text),
        minimum=0,
        maximum=9007199254740991,
      ),
      None,
    )
  }
  assert_eq(
    @wire_json.integer(@wire_json.parse("0"), minimum=1, maximum=1),
    None,
  )
  assert_eq(
    @wire_json.integer(@wire_json.parse("2"), minimum=1, maximum=1),
    None,
  )
}

///|
test "review wire parser keeps strict syntax and original numeric data" {
  let source = "{\"text\":\"1.0000000000000001\",\"array\":[1.0000000000000001,9007199254740993,1e-999]}"
  assert_eq(@wire_json.parse(source).stringify(), source)
  for
    source in [
      "{\"x\":1,}", "/*x*/1", "01", "NaN", "{x:1}", "\"\\uD800\"", "1 2",
    ] {
    let rejected = try {
      ignore(@wire_json.parse(source))
      false
    } catch {
      _ => true
    }
    assert_true(rejected)
  }
  assert_true(@wire_json.parse("{\"x\":1,\"x\":2}") is { "x": 2, .. })
}

///|
test "wire depth budget accepts its boundary and rejects deep arrays and objects" {
  for (open, close) in [("[", "]"), ("{\"x\":", "}")] {
    let nested = open.repeat(128) + "0" + close.repeat(128)
    assert_eq(@wire_json.parse(nested).stringify(), nested)
    for depth in [129, 1024, 10000] {
      let excessive = open.repeat(depth) + "0" + close.repeat(depth)
      let rejected = try {
        ignore(@wire_json.parse(excessive))
        false
      } catch {
        _ => true
      }
      assert_true(rejected)
    }
  }
}
