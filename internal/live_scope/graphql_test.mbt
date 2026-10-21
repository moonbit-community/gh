///|
test "GraphQL mutations require a confirmed node and a closed operation document" {
  let ledger = @live_scope.Ledger::new("run1", "fixture-id")
  ledger.intend_resource("issue", "fixture", "/issues", "issue")
  ledger.confirm_created(
    "issue",
    "123",
    locator="/repos/ZSeanYves/gh_test/issues/7",
  )
  let query = "mutation IssueDelete($issueId: ID!) { deleteIssue(input: { issueId: $issueId }) { clientMutationId } }"
  let body : Json = {
    "query": Json(query),
    "variables": { "issueId": "I_test" },
    "operationName": "IssueDelete",
  }
  let bytes = @utf8.encode(body.stringify())
  try ledger.approve_graphql_mutation("issue", "123", bytes) catch {
    @live_scope.OutsideScope => ()
    _ => fail("unexpected failure")
  } noraise {
    _ => fail("unbound node accepted")
  }
  ledger.bind_node("issue", "123", "I_test")
  let permit = ledger.approve_graphql_mutation("issue", "123", bytes)
  let policy = @live_scope.Policy::from_json({
    "schema": 1,
    "ledger": ledger.to_json(),
    "permits": [permit.to_json()],
  })
  assert_true(
    policy.allows("https://api.github.com", "POST", "/graphql", Some(bytes)),
  )
  let invalid_bodies : Array[Json] = [
    { "query": Json(query), "variables": { "issueId": "I_foreign" } },
    {
      "query": Json(query),
      "variables": { "issueId": "I_test", "repositoryId": "R_foreign" },
    },
    {
      "query": Json(
        query +
        " mutation Other { deleteIssue(input:{issueId:\"I_foreign\"}) { clientMutationId } }",
      ),
      "variables": { "issueId": "I_test" },
    },
    {
      "query": "mutation Other($id:ID!) { deleteIssue(input:{issueId:$id}) { clientMutationId } }",
      "variables": { "id": "I_test" },
    },
    {
      "query": Json(query),
      "variables": { "issueId": "I_test" },
      "operationName": "Other",
    },
  ]
  for invalid in invalid_bodies {
    let bytes = @utf8.encode(invalid.stringify())
    assert_false(
      policy.allows("https://api.github.com", "POST", "/graphql", Some(bytes)),
    )
    try ledger.approve_graphql_mutation("issue", "123", bytes) catch {
      @live_scope.OutsideScope => ()
      _ => fail("unexpected failure")
    } noraise {
      _ => fail("unreviewed GraphQL write approved")
    }
  }
}

///|
test "account intents start at a collection and bind the returned exact resource" {
  let ledger = @live_scope.Ledger::new("run1", "fixture-id")
  ledger.intend_account_resource("gist", "gist", "/gists")
  ledger.confirm_created("gist", "abcdef", locator="/gists/abcdef")
  let restored = @live_scope.Ledger::from_json(ledger.to_json())
  restored.check_owned("gist", "abcdef", "/gists/abcdef")
  for path in ["/gists/other", "/repos/ZSeanYves/other", "/user/keys/existing"] {
    try ledger.intend_account_resource("wrong", "gist", path) catch {
      @live_scope.OutsideScope => ()
      _ => fail("unexpected failure")
    } noraise {
      _ => fail("existing account resource treated as a creation")
    }
  }
}
