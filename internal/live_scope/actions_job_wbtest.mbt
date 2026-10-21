///|
test "job rerun requires an exact job receipt under an owned run and temporary repository" {
  let ledger = actions_ledger()
  ledger.intend_resource("job", "run", "/jobs", "job")
  let run = ledger.owned("run").locator
  ledger.confirm_created("job", "21", locator=run + "/jobs/21")
  let path = ledger.owned("repo").locator + "/actions/jobs/21/rerun"
  try ledger.approve_operation("job", "21", "POST", path) catch {
    _ => ()
  } noraise {
    _ => fail("missing job receipt accepted")
  }
  ledger.record_content_receipt("job", "21", "a".repeat(64))
  let body = b"{\"enable_debug_logging\":true}\n"
  let permit = ledger.approve_operation("job", "21", "POST", path, body~)
  let policy = actions_policy(ledger, permit)
  assert_true(policy.allows("https://api.github.com", "POST", path, Some(body)))
  for
    target in [
      path.replace_all(old="/21/", new="/22/"),
      path + "?run_id=other",
      run + "/jobs/21/rerun",
      "/repos/ZSeanYves/gh_test/actions/jobs/21/rerun",
      "/repos/moonbit-community/gh/actions/jobs/21/rerun",
      "/repos/ZSeanYves/other/actions/jobs/21/rerun",
    ] {
    assert_false(
      policy.allows("https://api.github.com", "POST", target, Some(body)),
    )
    try ledger.approve_operation("job", "21", "POST", target, body~) catch {
      _ => ()
    } noraise {
      _ => fail("foreign job operation accepted")
    }
  }
  try
    ledger.approve_operation(
      "job",
      "21",
      "POST",
      path,
      body=b"{\"run_id\":999}",
    )
  catch {
    _ => ()
  } noraise {
    _ => fail("unreviewed job payload")
  }
  // A job cannot make a run or repository writable after its parent becomes uncertain.
  ledger.mark_uncertain("run")
  let restored = Ledger::from_json(ledger.to_json())
  try restored.approve_operation("job", "21", "POST", path, body~) catch {
    _ => ()
  } noraise {
    _ => fail("unreconciled parent accepted")
  }
}

///|
test "job cleanup receipt is required before its run can be marked removed" {
  let ledger = actions_ledger()
  ledger.intend_resource("job", "run", "/jobs", "job")
  ledger.confirm_created(
    "job",
    "21",
    locator=ledger.owned("run").locator + "/jobs/21",
  )
  try ledger.confirm_removed("run", "13") catch {
    _ => ()
  } noraise {
    _ => fail("live child hidden by removed run")
  }
  ledger.confirm_removed("job", "21")
  ledger.confirm_removed("run", "13")
  ignore(Ledger::from_json(ledger.to_json()))
}
