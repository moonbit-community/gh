///|
test "account creations are private exact requests with separate immutable receipts" {
  let ledger = @live_scope.Ledger::new("account-run", "fixture-id")
  ledger.intend_account_resource("gist", "gist", "/gists")
  let body : Json = {
    "description": "gh-acceptance-account-run-gist",
    "public": false,
    "files": { "example.txt": { "content": "fixture" } },
  }
  let permit = ledger.approve_creation("gist", body)
  assert_true(
    permit.allows(
      "https://api.github.com",
      "POST",
      "/gists",
      Some(@utf8.encode(body.stringify())),
    ),
  )
  assert_false(
    permit.allows(
      "https://api.github.com",
      "POST",
      "/repos/ZSeanYves/other/issues",
      Some(@utf8.encode(body.stringify())),
    ),
  )
  ledger.mark_uncertain("gist")
  ledger.confirm_created("gist", "new-id", locator="/gists/new-id")
  let deletion = ledger.approve_mutation(
    "gist", "new-id", "DELETE", "/gists/new-id",
  )
  assert_true(
    deletion.allows("https://api.github.com", "DELETE", "/gists/new-id", None),
  )
  assert_false(
    deletion.allows("https://api.github.com", "DELETE", "/gists/existing", None),
  )
}

///|
test "account creation rejects public gists path names visibility changes and private keys" {
  let ledger = @live_scope.Ledger::new("guard", "fixture-id")
  ledger.intend_account_resource("gist", "gist", "/gists")
  for
    body in [
      Json::object({
        "description": "gh-acceptance-guard-gist",
        "public": true,
        "files": { "x": { "content": "x" } },
      }),
      Json::object({
        "description": "gh-acceptance-guard-gist",
        "public": false,
        "files": { "../x": { "content": "x" } },
      }),
      Json::object({
        "description": "existing",
        "public": false,
        "files": { "x": { "content": "x" } },
      }),
    ] {
    try ledger.approve_creation("gist", body) catch {
      _ => ()
    } noraise {
      _ => fail("unsafe account creation accepted")
    }
  }
  ledger.intend_account_resource("ssh", "ssh_key", "/user/keys")
  try
    ledger.approve_creation("ssh", {
      "title": "gh-acceptance-guard-key",
      "key": "-----BEGIN OPENSSH PRIVATE KEY-----",
    })
  catch {
    _ => ()
  } noraise {
    _ => fail("private key accepted")
  }
  let permit = ledger.approve_creation("ssh", {
    "title": "gh-acceptance-guard-key",
    "key": "ssh-ed25519 AAAA fixture-only",
  })
  assert_eq(permit.resource_key(), "ssh")
  ledger.confirm_created("gist", "new-id", locator="/gists/new-id")
  try
    ledger.approve_mutation(
      "gist",
      "new-id",
      "PATCH",
      "/gists/new-id",
      body=@utf8.encode("{\"public\":true}"),
    )
  catch {
    _ => ()
  } noraise {
    _ => fail("gist visibility mutation accepted")
  }
}
