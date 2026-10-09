///|
test "help names the MoonHub command groups" {
  let text = @cli.help_text()
  assert_true(text.contains("MoonHub"))
  assert_true(text.contains("issue"))
  assert_true(text.contains("trace"))
}
