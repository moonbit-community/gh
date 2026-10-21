///|
async test "acceptance challenge needs a real valid policy and is not a credential probe" {
  let directory = @fs.tmpdir(prefix="gh-scope-probe-")
  defer @fs.rmdir(directory, recursive=true)
  let path = directory + "/policy.json"
  let challenge = "0123456789abcdef0123456789abcdef"
  assert_eq(acceptance_probe(None, challenge).exit_code(), 1)
  @fs.write_file(path, "{\"schema\":1,\"permits\":[]}")
  let result = acceptance_probe(Some(path), challenge)
  assert_eq(result.exit_code(), 0)
  assert_true(
    @json.parse(result.stdout())
    is {
      "scope_protocol": Number(1, ..),
      "challenge": String("0123456789abcdef0123456789abcdef"),
      ..
    },
  )
  @fs.write_file(path, "{}")
  assert_eq(acceptance_probe(Some(path), challenge).exit_code(), 1)
}
