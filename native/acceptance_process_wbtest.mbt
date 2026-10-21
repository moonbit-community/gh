///|
async test "live process rejection does not invoke the supplied terminal runner" {
  let directory = @fs.tmpdir(prefix="gh-process-scope-")
  defer @fs.rmdir(directory, recursive=true)
  let path = directory + "/policy.json"
  @fs.write_file(path, "{\"schema\":1,\"permits\":[]}")
  let called = Ref(false)
  let result = run_terminal_process(
    "git",
    ["push", "origin", "HEAD"],
    acceptance_policy=path,
    runner=(_program, _args) => {
      called.val = true
      0
    },
  )
  assert_true(result is Err(InvalidCommand))
  assert_false(called.val)
}
