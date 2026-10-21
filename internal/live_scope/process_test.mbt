///|
test "acceptance blocks Git mutations and process escapes before launch" {
  let policy = @live_scope.Policy::from_json({ "schema": 1, "permits": [] })
  assert_true(policy.allows_process("git", ["rev-parse", "--show-toplevel"]))
  for
    args in [
      ["push", "origin", "HEAD"],
      ["clone", "https://github.com/ZSeanYves/other.git"],
      ["config", "--global", "core.sshCommand", "other"],
      ["-c", "alias.test=!echo mutation", "test"],
      ["remote", "set-url", "origin", "https://github.com/ZSeanYves/other.git"],
      ["-C", "/elsewhere", "push"],
      ["log", "--output=/elsewhere/file"],
      ["fetch", "origin"],
      ["checkout", "main"],
    ] {
    assert_false(policy.allows_process("git", args))
  }
  assert_false(policy.allows_process("sh", ["-c", "git push"]))
  assert_false(
    policy.allows_process("/tmp/git", ["rev-parse", "--show-toplevel"]),
  )
}
