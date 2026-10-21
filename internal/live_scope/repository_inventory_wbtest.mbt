///|
fn deletion_fixture() -> (Ledger, Json) raise {
  let ledger = Ledger::new("audit", "fixture-id")
  let hash = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  let locator = "/repos/ZSeanYves/gh-acceptance-audit-private"
  ledger.intend_repository("repo", "gh-acceptance-audit-private")
  ledger.confirm_created("repo", "repo-id")
  ledger.record_content_receipt("repo", "repo-id", hash)
  ledger.intend_resource("label", "repo", "/labels", "label")
  ledger.confirm_created(
    "label",
    "label-id",
    locator=locator + "/labels/run-label",
  )
  ledger.record_content_receipt("label", "label-id", hash)
  let collections : Map[String, Json] = Map([])
  for kind in repository_inventory_kinds {
    collections[kind] = [
      {
        "cursor": "",
        "next_cursor": Json::null(),
        "items": if kind == "label" {
          [
            {
              "id": "label-id",
              "locator": locator + "/labels/run-label",
              "content_sha256": hash,
            },
          ]
        } else {
          []
        },
      },
    ]
  }
  (
    ledger,
    {
      "repository_id": "repo-id",
      "locator": locator,
      "owner": "ZSeanYves",
      "owner_id": "owner-id",
      "private": true,
      "content_sha256": hash,
      "archived": true,
      "has_wiki": false,
      "has_pages": false,
      "observed_at_ms": 1000,
      "collections": Json::object(collections),
    },
  )
}

///|
test "absent initial workflow intents retain proof but cannot hide remote objects" {
  let (ledger, inventory) = deletion_fixture()
  let hash = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  ledger.intend_resource("workflow", "repo", "/actions/workflows", "workflow")
  ledger.confirm_not_created("workflow", "repo-id", hash)
  let restored = Ledger::from_json(ledger.to_json())
  assert_eq(restored.to_json(), ledger.to_json())
  ignore(
    restored.approve_repository_deletion(
      "repo",
      "repo-id",
      inventory,
      now_ms=1000L,
    ),
  )
  try restored.confirm_created("workflow", "999") catch {
    _ => ()
  } noraise {
    _ => fail("absent intent reused for creation")
  }
  try
    restored.approve_operation(
      "workflow", "999", "PUT", "/repos/ZSeanYves/gh-acceptance-audit-private/actions/workflows/999/disable",
    )
  catch {
    _ => ()
  } noraise {
    _ => fail("absent intent authorized a write")
  }
  guard inventory is Object(fields) &&
    fields.get("collections") is Some(Object(collections)) else {
    fail("inventory")
  }
  let changed = fields.copy()
  let collections = collections.copy()
  collections["workflow"] = [
    {
      "cursor": "",
      "next_cursor": Json::null(),
      "items": [
        {
          "id": "999",
          "locator": "/repos/ZSeanYves/gh-acceptance-audit-private/actions/workflows/999",
          "content_sha256": hash,
        },
      ],
    },
  ]
  changed["collections"] = Json::object(collections)
  try
    restored.approve_repository_deletion(
      "repo",
      "repo-id",
      Json::object(changed),
      now_ms=1000L,
    )
  catch {
    _ => ()
  } noraise {
    _ => fail("absence proof hid a real workflow")
  }
  try restored.confirm_not_created("label", "repo-id", hash) catch {
    _ => ()
  } noraise {
    _ => fail("existing resource marked absent")
  }
  restored.confirm_repository_removed("repo", "repo-id")
  assert_true(restored.resource("workflow").state == NotCreated)
  ignore(Ledger::from_json(restored.to_json()))
}

///|
test "repository deletion requires complete content receipts and expires before network use" {
  let (ledger, inventory) = deletion_fixture()
  let permit = ledger.approve_repository_deletion(
    "repo",
    "repo-id",
    inventory,
    now_ms=1000L,
  )
  let policy = Policy::from_json({
    "schema": 1,
    "ledger": ledger.to_json(),
    "permits": [permit.to_json()],
  })
  let path = "/repos/ZSeanYves/gh-acceptance-audit-private"
  assert_true(
    policy.allows("https://api.github.com", "DELETE", path, None, now_ms=31000L),
  )
  assert_false(
    policy.allows("https://api.github.com", "DELETE", path, None, now_ms=31001L),
  )
  assert_false(
    policy.allows("https://api.github.com", "DELETE", path, None, now_ms=999L),
  )
  assert_false(policy.allows("https://api.github.com", "DELETE", path, None))
  assert_false(
    policy.allows(
      "https://api.github.com",
      "DELETE",
      "/repos/ZSeanYves/gh_test",
      None,
      now_ms=1000L,
    ),
  )
  assert_false(
    policy.allows(
      "https://api.github.com",
      "DELETE",
      "/repos/moonbit-community/gh",
      None,
      now_ms=1000L,
    ),
  )
}

///|
test "foreign IDs content edits and missing audit pages deny repository deletion" {
  let (ledger, inventory) = deletion_fixture()
  guard inventory is Object(original) &&
    original["collections"] is Object(original_collections) else {
    fail("fixture")
  }
  for
    failure in [
      "foreign", "edited", "missing", "pagination", "duplicate", "uncertain",
    ] {
    let fields = original.copy()
    let collections = original_collections.copy()
    let locator = "/repos/ZSeanYves/gh-acceptance-audit-private/labels/run-label"
    let item : Json = {
      "id": if failure == "foreign" {
        "other-id"
      } else {
        "label-id"
      },
      "locator": locator,
      "content_sha256": if failure == "edited" {
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
      } else {
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      },
    }
    collections["label"] = [
      {
        "cursor": "",
        "next_cursor": if failure == "pagination" {
          Json("next-page")
        } else {
          Json::null()
        },
        "items": if failure == "missing" {
          []
        } else if failure == "duplicate" {
          [item, item]
        } else {
          [item]
        },
      },
    ]
    fields["collections"] = Json::object(collections)
    if failure == "uncertain" {
      ledger.mark_uncertain("label")
    }
    try
      ledger.approve_repository_deletion(
        "repo",
        "repo-id",
        Json::object(fields),
        now_ms=1000L,
      )
    catch {
      _ => ()
    } noraise {
      _ => fail("unsafe repository deletion: " + failure)
    }
  }
  ledger.confirm_created("label", "label-id")
  let collections = original_collections.copy()
  collections.remove("workflow")
  let fields = original.copy()
  fields["collections"] = Json::object(collections)
  try
    ledger.approve_repository_deletion(
      "repo",
      "repo-id",
      Json::object(fields),
      now_ms=1000L,
    )
  catch {
    _ => ()
  } noraise {
    _ => fail("incomplete category inventory accepted")
  }
}

///|
test "deletion permit revalidates tampered inventory and cannot manufacture ownership from a name" {
  let (ledger, inventory) = deletion_fixture()
  let permit = ledger.approve_repository_deletion(
    "repo",
    "repo-id",
    inventory,
    now_ms=1000L,
  )
  guard permit.to_json() is Object(fields) && inventory is Object(audit) else {
    fail("fixture")
  }
  let changed = audit.copy()
  changed["repository_id"] = Json("different-repository-id")
  let fields = fields.copy()
  fields["inventory"] = Json::object(changed)
  let policy = Policy::from_json({
    "schema": 1,
    "ledger": ledger.to_json(),
    "permits": [Json::object(fields)],
  })
  assert_false(
    policy.allows(
      "https://api.github.com",
      "DELETE",
      "/repos/ZSeanYves/gh-acceptance-audit-private",
      None,
      now_ms=1000L,
    ),
  )
  let unowned = Ledger::new("audit", "fixture-id")
  unowned.intend_repository("repo", "gh-acceptance-audit-private")
  try
    unowned.approve_repository_deletion(
      "repo",
      "repo-id",
      inventory,
      now_ms=1000L,
    )
  catch {
    _ => ()
  } noraise {
    _ => fail("marker became an immutable receipt")
  }
}

///|
test "repository deletion rejects active public wiki or pages audit state" {
  let (ledger, inventory) = deletion_fixture()
  guard inventory is Object(original) else { fail("fixture") }
  for
    (key, value) in [
      ("archived", Json(false)),
      ("private", Json(false)),
      ("has_wiki", Json(true)),
      ("has_pages", Json(true)),
    ] {
    let changed = original.copy()
    changed[key] = value
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
      _ => fail("unsafe repository state accepted: " + key)
    }
  }
}

///|
test "repository absence completes only its recorded descendants" {
  let (ledger, _) = deletion_fixture()
  ledger.intend_repository("other", "gh-acceptance-audit-other")
  ledger.confirm_created("other", "other-id")
  ledger.mark_uncertain("repo")
  ledger.confirm_repository_removed("repo", "repo-id")
  assert_true(ledger.resource("repo").state == Removed)
  assert_true(ledger.resource("label").state == Removed)
  assert_true(ledger.resource("other").state == Created)
  assert_true(ledger.resource("fixture").state == Created)
  ignore(Ledger::from_json(ledger.to_json()))
}
