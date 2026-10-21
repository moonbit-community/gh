///|
test "branch creation is restricted to current-run names and exact fixture paths" {
  let ledger = @live_scope.Ledger::new("branch", "fixture-id")
  ledger.intend_resource("branch", "fixture", "/git/refs", "git_ref")
  let body : Json = {
    "ref": "refs/heads/gh-acceptance-branch-test",
    "sha": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  }
  let permit = ledger.approve_creation("branch", body)
  let policy = @live_scope.Policy::from_json({
    "schema": 1,
    "ledger": ledger.to_json(),
    "permits": [permit.to_json()],
  })
  assert_true(
    policy.allows(
      "https://api.github.com",
      "POST",
      "/repos/ZSeanYves/gh_test/git/refs",
      Some(@utf8.encode(body.stringify())),
    ),
  )
  assert_false(
    policy.allows(
      "https://api.github.com",
      "POST",
      "/repos/moonbit-community/gh/git/refs",
      Some(@utf8.encode(body.stringify())),
    ),
  )
  for
    ref_name in [
      "refs/heads/main", "refs/heads/gh-acceptance-other-test", "refs/tags/gh-acceptance-branch-test",
      "refs/heads/gh-acceptance-branch-../main", "refs/heads/gh-acceptance-branch-test%2Fmain",
    ] {
    let invalid : Json = {
      "ref": ref_name,
      "sha": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    }
    try ledger.approve_creation("branch", invalid) catch {
      _ => ()
    } noraise {
      _ => fail("unowned branch creation accepted")
    }
  }
  try
    ledger.approve_creation("branch", {
      "ref": "refs/heads/gh-acceptance-branch-test",
      "sha": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      "force": true,
    })
  catch {
    _ => ()
  } noraise {
    _ => fail("unreviewed Git write field accepted")
  }
}

///|
test "branch deletion cannot target a different ref or update the recorded branch" {
  let ledger = @live_scope.Ledger::new("branch", "fixture-id")
  ledger.intend_resource("branch", "fixture", "/git/refs", "git_ref")
  let path = "/repos/ZSeanYves/gh_test/git/refs/heads/gh-acceptance-branch-test"
  ledger.confirm_created("branch", "ref-id", locator=path)
  let permit = ledger.approve_mutation("branch", "ref-id", "DELETE", path)
  let policy = @live_scope.Policy::from_json({
    "schema": 1,
    "ledger": ledger.to_json(),
    "permits": [permit.to_json()],
  })
  assert_true(policy.allows("https://api.github.com", "DELETE", path, None))
  assert_false(
    policy.allows(
      "https://api.github.com",
      "DELETE",
      "/repos/ZSeanYves/gh_test/git/refs/heads/main",
      None,
    ),
  )
  try ledger.approve_mutation("branch", "different-id", "DELETE", path) catch {
    _ => ()
  } noraise {
    _ => fail("unobserved ref ID accepted")
  }
  try
    ledger.approve_mutation(
      "branch",
      "ref-id",
      "PATCH",
      path,
      body=@utf8.encode(
        "{\"sha\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"force\":true}",
      ),
    )
  catch {
    _ => ()
  } noraise {
    _ => fail("Git ref update has no reviewed permit")
  }
}
