///|
test "account ledgers bind writes to one owner and credential without inheriting fixtures" {
  let hash = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  let ledger = Ledger::for_account("bound", "ZSeanYvesMIN", "321231243", hash)
  ledger.intend_repository("repo", "gh-acceptance-bound-private")
  let body : Json = { "name": "gh-acceptance-bound-private", "private": true }
  let permit = ledger.approve_creation("repo", body)
  let restored = Ledger::from_json(ledger.to_json())
  assert_eq(restored.to_json(), ledger.to_json())
  let policy = Policy::from_json({
    "schema": 1,
    "ledger": restored.to_json(),
    "permits": [permit.to_json()],
  })
  let bytes = @utf8.encode(body.stringify())
  assert_true(
    policy.allows(
      "https://api.github.com",
      "POST",
      "/user/repos",
      Some(bytes),
      credential_sha256=hash,
    ),
  )
  assert_false(
    policy.allows("https://api.github.com", "POST", "/user/repos", Some(bytes)),
  )
  assert_false(
    policy.allows(
      "https://api.github.com",
      "POST",
      "/user/repos",
      Some(bytes),
      credential_sha256="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    ),
  )
  try restored.intend_resource("issue", "fixture", "/issues", "issue") catch {
    UnknownResource => ()
    _ => fail("unexpected scope error")
  } noraise {
    _ => fail("second account inherited fixture writes")
  }
  for owner in ["ZSeanYves", "moonbit-community", "unapproved"] {
    assert_false(
      policy.allows(
        "https://api.github.com",
        "POST",
        "/repos/" + owner + "/gh_test/issues",
        Some(bytes),
        credential_sha256=hash,
      ),
    )
  }
  for name in ["gh_test", "gh-acceptance-other-private", "../other"] {
    try restored.intend_repository("other", name) catch {
      _ => ()
    } noraise {
      _ => fail("unowned repository accepted")
    }
  }
  restored.confirm_created("repo", "123")
  try
    restored.check_owned(
      "repo", "123", "/repos/ZSeanYves/gh-acceptance-bound-private",
    )
  catch {
    OutsideScope => ()
    _ => fail("wrong error")
  } noraise {
    _ => fail("owner swap accepted")
  }
  guard restored.to_json() is Object(fields) else { fail("ledger") }
  for
    (field, value) in [
      ("owner", Json("unapproved")),
      ("owner", Json("ZSeanYves")),
      ("owner_id", Json("../1")),
      ("credential_sha256", Json("")),
      ("schema", Json(1)),
    ] {
    let changed = fields.copy()
    changed[field] = value
    try Ledger::from_json(Json::object(changed)) catch {
      _ => ()
    } noraise {
      _ => fail("invalid binding accepted: " + field)
    }
  }
}

///|
test "account-bound cleanup rejects mismatched owner IDs and foreign collaborators" {
  let (ledger, inventory) = deletion_fixture(account_bound=true)
  ignore(
    ledger.approve_repository_deletion(
      "repo",
      "repo-id",
      inventory,
      now_ms=1000L,
    ),
  )
  guard inventory is Object(fields) &&
    fields.get("collections") is Some(Object(collections)) else {
    fail("inventory")
  }
  for (field, value) in [("owner", "ZSeanYves"), ("owner_id", "999")] {
    let changed = fields.copy()
    changed[field] = Json(value)
    try
      ledger.approve_repository_deletion(
        "repo",
        "repo-id",
        Json::object(changed),
        now_ms=1000L,
      )
    catch {
      _ => ()
    } noraise {
      _ => fail("owner mismatch accepted")
    }
  }
  let changed = fields.copy()
  let collections = collections.copy()
  collections["collaborator"] = [
    {
      "cursor": "",
      "next_cursor": Json::null(),
      "items": [
        {
          "id": "999",
          "locator": "/repos/ZSeanYvesMIN/gh-acceptance-audit-private/collaborators/ZSeanYves",
          "content_sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        },
      ],
    },
  ]
  changed["collections"] = Json::object(collections)
  try
    ledger.approve_repository_deletion(
      "repo",
      "repo-id",
      Json::object(changed),
      now_ms=1000L,
    )
  catch {
    _ => ()
  } noraise {
    _ => fail("unregistered collaborator accepted")
  }
}
