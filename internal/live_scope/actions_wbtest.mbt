///|
fn actions_ledger() -> Ledger raise {
  let ledger = Ledger::new("actions", "fixture-id")
  ledger.intend_repository("repo", "gh-acceptance-actions-repository")
  ledger.confirm_created("repo", "11")
  ledger.intend_resource("branch", "repo", "/git/refs", "git_ref")
  ledger.confirm_created(
    "branch",
    "ref-id",
    locator="/repos/ZSeanYves/gh-acceptance-actions-repository/git/refs/heads/main",
  )
  ledger.record_content_receipt(
    "branch", "ref-id", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  )
  for
    (key, kind, collection, id) in [
      ("workflow", "workflow", "/actions/workflows", "12"),
      ("run", "run", "/actions/runs", "13"),
      ("artifact", "artifact", "/actions/artifacts", "14"),
      ("cache", "cache", "/actions/caches", "15"),
    ] {
    ledger.intend_resource(key, "repo", collection, kind)
    ledger.confirm_created(
      key,
      id,
      locator="/repos/ZSeanYves/gh-acceptance-actions-repository" +
        collection +
        "/" +
        id,
    )
  }
  ledger
}

///|
fn actions_policy(ledger : Ledger, permit : Permit) -> Policy raise {
  Policy::from_json({
    "schema": 1,
    "ledger": ledger.to_json(),
    "permits": [permit.to_json()],
  })
}

///|
test "workflow file creation cannot overwrite files or write to an existing repository" {
  let ledger = actions_ledger()
  let path = "/repos/ZSeanYves/gh-acceptance-actions-repository/contents/.github/workflows/gh-acceptance-actions.yml"
  let fields : Map[String, Json] = {
    "message": "gh-acceptance-actions-workflow",
    "content": "bmFtZTogdGVzdAo=",
  }
  let body = @utf8.encode(Json::object(fields).stringify())
  let permit = ledger.approve_operation("repo", "11", "PUT", path, body~)
  let policy = actions_policy(ledger, permit)
  assert_true(policy.allows("https://api.github.com", "PUT", path, Some(body)))
  for
    forbidden in [
      "/repos/ZSeanYves/gh_test/contents/.github/workflows/gh-acceptance-actions.yml",
      "/repos/moonbit-community/gh/contents/.github/workflows/gh-acceptance-actions.yml",
      "/repos/ZSeanYves/another/contents/.github/workflows/gh-acceptance-actions.yml",
      path + "/../other.yml",
      path + "?ref=other",
      path.replace_all(old="gh-acceptance-actions.yml", new="existing.yml"),
    ] {
    assert_false(
      policy.allows("https://api.github.com", "PUT", forbidden, Some(body)),
    )
    try ledger.approve_operation("repo", "11", "PUT", forbidden, body~) catch {
      _ => ()
    } noraise {
      _ => fail("unowned workflow path accepted")
    }
  }
  for field in ["sha", "branch", "committer", "unexpected"] {
    let changed = fields.copy()
    changed[field] = Json("forbidden")
    let body = @utf8.encode(Json::object(changed).stringify())
    try ledger.approve_operation("repo", "11", "PUT", path, body~) catch {
      _ => ()
    } noraise {
      _ => fail("workflow creation accepted overwrite or unreviewed field")
    }
  }
  assert_false(
    policy.allows("https://api.github.com", "PUT", path, Some(b"{}")),
  )
  try
    ledger.approve_operation("fixture", "fixture-id", "PUT", path, body~)
  catch {
    _ => ()
  } noraise {
    _ => fail("fixture repository accepted workflow initialization")
  }
}

///|
test "workflow dispatch binds inputs to a registered branch in the same temporary repository" {
  let ledger = actions_ledger()
  let path = "/repos/ZSeanYves/gh-acceptance-actions-repository/actions/workflows/12/dispatches"
  let good : Json = {
    "ref": "main",
    "inputs": { "mode": "success", "nonce": "gh-acceptance-actions-success" },
  }
  let body = @utf8.encode(good.stringify())
  let permit = ledger.approve_operation("workflow", "12", "POST", path, body~)
  assert_true(
    actions_policy(ledger, permit).allows(
      "https://api.github.com",
      "POST",
      path,
      Some(body),
    ),
  )
  let detailed : Json = {
    "ref": "main",
    "inputs": { "mode": "success", "nonce": "gh-acceptance-actions-success" },
    "return_run_details": true,
  }
  let detailed_body = @utf8.encode(detailed.stringify())
  let detailed_permit = ledger.approve_operation(
    "workflow",
    "12",
    "POST",
    path,
    body=detailed_body,
  )
  assert_true(
    actions_policy(ledger, detailed_permit).allows(
      "https://api.github.com",
      "POST",
      path,
      Some(detailed_body),
    ),
  )
  let invalid_cases : Array[Json] = [
    {
      "ref": "other",
      "inputs": { "mode": "success", "nonce": "gh-acceptance-actions-success" },
    },
    { "ref": "main", "inputs": { "mode": "success", "nonce": "foreign-run" } },
    {
      "ref": "main",
      "inputs": {
        "mode": "arbitrary",
        "nonce": "gh-acceptance-actions-success",
      },
    },
    {
      "ref": "main",
      "inputs": {
        "mode": "success",
        "nonce": "gh-acceptance-actions-success",
        "repository": "foreign",
      },
    },
    {
      "ref": "main",
      "inputs": { "mode": "success", "nonce": "gh-acceptance-actions-success" },
      "unexpected": true,
    },
    {
      "ref": "main",
      "inputs": { "mode": "success", "nonce": "gh-acceptance-actions-success" },
      "return_run_details": false,
    },
  ]
  for invalid in invalid_cases {
    let changed = @utf8.encode(invalid.stringify())
    try
      ledger.approve_operation("workflow", "12", "POST", path, body=changed)
    catch {
      _ => ()
    } noraise {
      _ => fail("unowned dispatch accepted")
    }
    assert_false(
      actions_policy(ledger, permit).allows(
        "https://api.github.com",
        "POST",
        path,
        Some(changed),
      ),
    )
  }
  ledger.mark_uncertain("branch")
  try ledger.approve_operation("workflow", "12", "POST", path, body~) catch {
    _ => ()
  } noraise {
    _ => fail("dispatch accepted an unreconciled branch")
  }
}

///|
test "Actions operation suffixes and cleanup use exact known resource IDs" {
  let ledger = actions_ledger()
  let repository = "/repos/ZSeanYves/gh-acceptance-actions-repository"
  for
    (key, id, verb, suffix) in [
      ("workflow", "12", "PUT", "/enable"),
      ("workflow", "12", "PUT", "/disable"),
      ("run", "13", "POST", "/cancel"),
      ("run", "13", "POST", "/rerun"),
      ("run", "13", "POST", "/rerun-failed-jobs"),
    ] {
    let path = ledger.owned(key).locator + suffix
    let permit = ledger.approve_operation(key, id, verb, path)
    let policy = actions_policy(ledger, permit)
    assert_true(policy.allows("https://api.github.com", verb, path, None))
    assert_false(
      policy.allows("https://api.github.com", verb, path + "/other", None),
    )
    try ledger.approve_operation(key, "9999", verb, path) catch {
      _ => ()
    } noraise {
      _ => fail("operation accepted a different ID")
    }
  }
  for
    (key, id, collection) in [
      ("run", "13", "runs"),
      ("artifact", "14", "artifacts"),
      ("cache", "15", "caches"),
    ] {
    let path = repository + "/actions/" + collection + "/" + id
    let permit = ledger.approve_mutation(key, id, "DELETE", path)
    let policy = actions_policy(ledger, permit)
    assert_true(policy.allows("https://api.github.com", "DELETE", path, None))
    assert_false(
      policy.allows(
        "https://api.github.com",
        "DELETE",
        repository + "/actions/" + collection,
        None,
      ),
    )
    ledger.intend_resource(
      "fixture-" + key,
      "fixture",
      "/actions/" + collection,
      key,
    )
    let fixture_path = "/repos/ZSeanYves/gh_test/actions/" +
      collection +
      "/" +
      id
    ledger.confirm_created("fixture-" + key, id, locator=fixture_path)
    try
      ledger.approve_mutation("fixture-" + key, id, "DELETE", fixture_path)
    catch {
      _ => ()
    } noraise {
      _ => fail("Actions cleanup accepted fixture repository resource")
    }
  }
}

///|
test "Actions debug rerun permits bind exact body bytes and reject extra fields" {
  let ledger = actions_ledger()
  let path = ledger.owned("run").locator + "/rerun"
  let body = b"{\"enable_debug_logging\":true}\n"
  let permit = ledger.approve_operation("run", "13", "POST", path, body~)
  let policy = actions_policy(ledger, permit)
  assert_true(policy.allows("https://api.github.com", "POST", path, Some(body)))
  assert_false(policy.allows("https://api.github.com", "POST", path, None))
  assert_false(
    policy.allows(
      "https://api.github.com",
      "POST",
      path,
      Some(b"{\"enable_debug_logging\":false}\n"),
    ),
  )
  for
    invalid in [
      b"{\"enable_debug_logging\":\"true\"}", b"{\"enable_debug_logging\":true,\"ref\":\"other\"}",
      b"{\"repository_id\":999}",
    ] {
    try
      ledger.approve_operation("run", "13", "POST", path, body=invalid)
    catch {
      _ => ()
    } noraise {
      _ => fail("rerun accepted an unreviewed payload")
    }
  }
}
