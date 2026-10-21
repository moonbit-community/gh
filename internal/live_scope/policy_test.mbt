///|
test "read-only policy denies all REST writes and mixed GraphQL documents" {
  let policy = @live_scope.Policy::from_json({ "schema": 1, "permits": [] })
  assert_true(policy.allows("https://api.github.com", "GET", "/user", None))
  for
    path in [
      "/repos/ZSeanYves/other", "/repos/moonbit-community/gh", "/user/keys/1", "/repos/ZSeanYves/gh_test",
    ] {
    assert_false(policy.allows("https://api.github.com", "DELETE", path, None))
  }
  assert_true(
    policy.allows(
      "https://api.github.com",
      "POST",
      "/graphql",
      Some(b"{\"query\":\"query Viewer { viewer { login } }\"}"),
    ),
  )
  assert_false(
    policy.allows(
      "https://api.github.com",
      "POST",
      "/graphql",
      Some(
        b"{\"query\":\"query Viewer { viewer { login } } mutation Delete { deleteIssue(input:{issueId:\\\"other\\\"}) { clientMutationId } }\",\"operationName\":\"Delete\"}",
      ),
    ),
  )
  assert_false(
    policy.allows(
      "https://api.github.com",
      "GET",
      "/graphql?query=mutation",
      None,
    ),
  )
}

///|
test "serialized permissions require a matching receipt and revalidate mutation fields" {
  let ledger = @live_scope.Ledger::new("run1", "fixture-id")
  ledger.intend_resource("issue", "fixture", "/issues", "issue")
  ledger.confirm_created(
    "issue",
    "issue-id",
    locator="/repos/ZSeanYves/gh_test/issues/12",
  )
  let body = b"{\"state\":\"closed\"}"
  let permit = ledger
    .approve_mutation(
      "issue",
      "issue-id",
      "PATCH",
      "/repos/ZSeanYves/gh_test/issues/12",
      body~,
    )
    .to_json()
  let policy = @live_scope.Policy::from_json({
    "schema": 1,
    "ledger": ledger.to_json(),
    "permits": [permit],
  })
  assert_true(
    policy.allows(
      "https://api.github.com",
      "PATCH",
      "/repos/ZSeanYves/gh_test/issues/12",
      Some(body),
    ),
  )
  try
    @live_scope.Policy::from_json({ "schema": 1, "permits": [permit] })
  catch {
    @live_scope.InvalidLedger => ()
    _ => fail("unexpected failure")
  } noraise {
    _ => fail("missing ledger accepted")
  }
  try
    ledger.approve_mutation(
      "issue",
      "issue-id",
      "PATCH",
      "/repos/ZSeanYves/gh_test/issues/12",
      body=b"{\"milestone\":1}",
    )
  catch {
    @live_scope.OutsideScope => ()
    _ => fail("unexpected failure")
  } noraise {
    _ => fail("unregistered related object accepted")
  }
}

///|
test "a run marker cannot replace a repository creation receipt" {
  let ledger = @live_scope.Ledger::new("run1", "fixture-id")
  ledger.intend_repository("repo", "gh-acceptance-run1-tmp")
  let forged : Json = {
    "origin": "https://api.github.com",
    "verb": "DELETE",
    "path": "/repos/ZSeanYves/gh-acceptance-run1-tmp",
    "resource_key": "repo",
    "creation": false,
    "body_sha256": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
  }
  try
    @live_scope.Policy::from_json({
      "schema": 1,
      "ledger": ledger.to_json(),
      "permits": [forged],
    })
  catch {
    @live_scope.UnknownResource => ()
    _ => fail("unexpected failure")
  } noraise {
    _ => fail("name-only deletion accepted")
  }
}

///|
test "serialized permissions cannot authorize other repositories or arbitrary GraphQL" {
  for
    path in [
      "/repos/ZSeanYves/other/issues/1", "/repos/moonbit-community/gh/issues/1",
      "/graphql", "/repos/ZSeanYves/gh_test", "/repos/ZSeanYves/gh_test/../other",
    ] {
    try
      @live_scope.Policy::from_json({
        "schema": 1,
        "permits": [
          {
            "origin": "https://api.github.com",
            "verb": "DELETE",
            "path": path,
            "resource_key": "test",
            "body_sha256": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
          },
        ],
      })
    catch {
      @live_scope.OutsideScope | @live_scope.InvalidLedger => ()
      _ => fail("unexpected failure")
    } noraise {
      _ => fail("unsafe policy accepted")
    }
  }
}
