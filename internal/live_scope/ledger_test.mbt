///|
test "only created repository receipts admit disposable repositories" {
  let ledger = @live_scope.Ledger::new("run1", "fixture-id")
  ledger.intend_repository("temporary", "gh-acceptance-run1-actions")
  try
    ledger.mutation_target(
      "temporary", "123", "/repos/ZSeanYves/gh-acceptance-run1-actions",
    )
  catch {
    @live_scope.InvalidTransition => ()
    _ => fail("unexpected failure")
  } noraise {
    _ => fail("intent must not authorize writes")
  }
  ledger.confirm_created("temporary", "123")
  ledger.mutation_target(
    "temporary", "123", "/repos/ZSeanYves/gh-acceptance-run1-actions",
  )
  for name in ["gh_test", "personal", "gh-acceptance-other-actions"] {
    try ledger.intend_repository(name, name) catch {
      @live_scope.OutsideScope => ()
      _ => fail("unexpected failure")
    } noraise {
      _ => fail("existing repository accepted")
    }
  }
}

///|
test "fixture and development repository cannot become destructive targets" {
  let ledger = @live_scope.Ledger::new("run1", "fixture-id")
  try
    ledger.mutation_target("fixture", "fixture-id", "/repos/ZSeanYves/gh_test")
  catch {
    @live_scope.OutsideScope => ()
    _ => fail("unexpected failure")
  } noraise {
    _ => fail("fixture root is protected")
  }
  for
    path in [
      "/../gh", "//other", "/%2e%2e/gh", "/issues?owner=other", "/issues\\other",
      "/labels/%252e%252e", "/labels/run%2f..%2fother", "/labels/%5cother", "/labels/%00",
      "/labels/%ff", "/labels/%", "/labels/%2",
    ] {
    try ledger.intend_resource("escape", "fixture", path, "issue") catch {
      @live_scope.OutsideScope => ()
      _ => fail("unexpected failure")
    } noraise {
      _ => fail("unsafe locator accepted")
    }
  }
}

///|
test "encoded label names remain exact owned paths" {
  let ledger = @live_scope.Ledger::new("encoded", "fixture-id")
  ledger.intend_resource("label", "fixture", "/labels", "label")
  let path = "/repos/ZSeanYves/gh_test/labels/gh-acceptance-encoded-%E6%B5%8B%E8%AF%95%20label"
  ledger.confirm_created("label", "label-id", locator=path)
  let permit = ledger.approve_mutation("label", "label-id", "DELETE", path)
  assert_true(permit.allows("https://api.github.com", "DELETE", path, None))
  assert_false(
    permit.allows(
      "https://api.github.com",
      "DELETE",
      "/repos/ZSeanYves/gh_test/labels/gh-acceptance-encoded-test%20label",
      None,
    ),
  )
}

///|
test "resources need exact ownership and cleanup follows dependency order" {
  let ledger = @live_scope.Ledger::new("run1", "fixture-id")
  ledger.intend_resource("issue", "fixture", "/issues/12", "issue")
  ledger.confirm_created("issue", "issue-id")
  ledger.intend_resource("comment", "issue", "/comments/99", "comment")
  ledger.confirm_created("comment", "comment-id")
  for
    (id, path) in [
      ("wrong-id", "/repos/ZSeanYves/gh_test/issues/12"),
      ("issue-id", "/repos/ZSeanYves/other/issues/12"),
      ("issue-id", "/repos/moonbit-community/gh/issues/12"),
    ] {
    try ledger.check_owned("issue", id, path) catch {
      @live_scope.OutsideScope => ()
      _ => fail("unexpected failure")
    } noraise {
      _ => fail("wrong target accepted")
    }
  }
  try ledger.confirm_removed("issue", "issue-id") catch {
    @live_scope.InvalidTransition => ()
    _ => fail("unexpected failure")
  } noraise {
    _ => fail("cleanup discarded a live child")
  }
  ledger.confirm_removed("comment", "comment-id")
  ledger.confirm_removed("issue", "issue-id")
}

///|
test "pending parent mutations preserve durable child receipts but block writes" {
  let ledger = @live_scope.Ledger::new("run1", "fixture-id")
  ledger.intend_repository("repo", "gh-acceptance-run1-a")
  ledger.confirm_created("repo", "repo-id")
  ledger.intend_resource("key", "repo", "/keys", "deploy_key")
  ledger.confirm_created(
    "key",
    "key-id",
    locator="/repos/ZSeanYves/gh-acceptance-run1-a/keys/1",
  )
  ledger.mark_uncertain("repo")
  let recovered = @live_scope.Ledger::from_json(ledger.to_json())
  try
    recovered.check_owned(
      "key", "key-id", "/repos/ZSeanYves/gh-acceptance-run1-a/keys/1",
    )
  catch {
    @live_scope.InvalidTransition => ()
    _ => fail("unexpected failure")
  } noraise {
    _ => fail("pending parent allowed a child write")
  }
  recovered.confirm_created("repo", "repo-id")
  recovered.mark_uncertain("key")
  recovered.confirm_removed("key", "key-id")
  ignore(@live_scope.Ledger::from_json(recovered.to_json()))
}

///|
test "uncertain writes require reconciliation before more mutation" {
  let ledger = @live_scope.Ledger::new("run1", "fixture-id")
  ledger.intend_resource("issue", "fixture", "/issues/12", "issue")
  ledger.mark_uncertain("issue")
  try
    ledger.mutation_target("issue", "id", "/repos/ZSeanYves/gh_test/issues/12")
  catch {
    @live_scope.InvalidTransition => ()
    _ => fail("unexpected failure")
  } noraise {
    _ => fail("uncertain receipt accepted")
  }
  ledger.confirm_created("issue", "id")
  ledger.mutation_target("issue", "id", "/repos/ZSeanYves/gh_test/issues/12")
}
