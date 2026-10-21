///|
test "offset search retains original anchors and word boundaries" {
  assert_false(@regexp.compile("^a").execute_from("aa", 1).matched())
  assert_false(@regexp.compile("\\bb").execute_from("ab", 1).matched())
  let matched = @regexp.compile("b").execute_from("ab b", 2)
  assert_eq(matched.before().to_owned(), "ab ")
  assert_eq(matched.get(0).unwrap().start_offset(), 3)
  assert_false(@regexp.compile(".").execute_from("a", 2).matched())
}

///|
test "offset search keeps Unicode capture positions in the original input" {
  let result = @regexp.compile("(?<value>😀)").execute_from("a😀a😀", 3)
  assert_true(result.matched())
  assert_eq(result.get(1).unwrap().start_offset(), 4)
  assert_eq(result.get(1).unwrap().to_owned(), "😀")
}
