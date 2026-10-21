///|
test "mutation approvals bind path method body and origin" {
  let ledger = @live_scope.Ledger::new("run1", "fixture-id")
  ledger.intend_resource("issue", "fixture", "/issues", "issue")
  ledger.confirm_created(
    "issue",
    "issue-id",
    locator="/repos/ZSeanYves/gh_test/issues/12",
  )
  let permit = ledger.approve_mutation(
    "issue",
    "issue-id",
    "PATCH",
    "/repos/ZSeanYves/gh_test/issues/12",
    body=b"{\"state\":\"closed\"}",
  )
  assert_true(
    permit.allows(
      "https://api.github.com",
      "PATCH",
      "/repos/ZSeanYves/gh_test/issues/12",
      Some(b"{\"state\":\"closed\"}"),
    ),
  )
  for
    (origin, verb, path, body) in [
      (
        "https://evil.example",
        "PATCH",
        "/repos/ZSeanYves/gh_test/issues/12",
        Some(b"{\"state\":\"closed\"}"),
      ),
      (
        "https://api.github.com",
        "DELETE",
        "/repos/ZSeanYves/gh_test/issues/12",
        Some(b"{\"state\":\"closed\"}"),
      ),
      (
        "https://api.github.com",
        "PATCH",
        "/repos/ZSeanYves/other/issues/12",
        Some(b"{\"state\":\"closed\"}"),
      ),
      (
        "https://api.github.com",
        "PATCH",
        "/repos/ZSeanYves/gh_test/issues/12",
        Some(b"{\"state\":\"open\"}"),
      ),
    ] {
    assert_false(permit.allows(origin, verb, path, body))
  }
}

///|
test "repository receipt alone cannot authorize deleting unaudited contents" {
  let ledger = @live_scope.Ledger::new("run1", "fixture-id")
  ledger.intend_repository("repo", "gh-acceptance-run1-a")
  ledger.confirm_created("repo", "id")
  try
    ledger.approve_mutation(
      "repo", "id", "DELETE", "/repos/ZSeanYves/gh-acceptance-run1-a",
    )
  catch {
    @live_scope.OutsideScope => ()
    _ => fail("unexpected failure")
  } noraise {
    _ => fail("repository deletion without contents audit")
  }
}

///|
test "only explicit private repository creation and marker-owned issue creation are approved" {
  let ledger = @live_scope.Ledger::new("run1", "fixture-id")
  ledger.intend_repository("repo", "gh-acceptance-run1-actions")
  ignore(
    ledger.approve_creation("repo", {
      "name": "gh-acceptance-run1-actions",
      "private": true,
    }),
  )
  try
    ledger.approve_creation("repo", {
      "name": "gh-acceptance-run1-actions",
      "private": false,
    })
  catch {
    @live_scope.OutsideScope => ()
    _ => fail("unexpected failure")
  } noraise {
    _ => fail("public repository approved")
  }
  ledger.intend_resource("issue", "fixture", "/issues", "issue")
  ignore(
    ledger.approve_creation("issue", { "title": "gh-acceptance-run1-issue" }),
  )
  try
    ledger.approve_creation("issue", {
      "title": "gh-acceptance-run1-issue",
      "assignees": ["someone"],
    })
  catch {
    @live_scope.OutsideScope => ()
    _ => fail("unexpected failure")
  } noraise {
    _ => fail("cross-account side effect approved")
  }
}
