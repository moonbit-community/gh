///|
fn fixture_hex(bytes : Bytes) -> String {
  let text = StringBuilder()
  for b in bytes {
    text.write_char("0123456789abcdef".get_char(b.to_int() / 16).unwrap())
    text.write_char("0123456789abcdef".get_char(b.to_int() % 16).unwrap())
  }
  text.to_string()
}

///|
fn signed_test_metadata(value : Json) -> Bytes raise {
  signed_test_metadata_with_key(value, b'\x71', "test")
}

///|
fn signed_test_metadata_with_key(
  value : Json,
  seed : Byte,
  key_id : String,
) -> Bytes raise {
  // Synthetic deterministic test key; never installed or used on GitHub.
  let key = @ed25519.PrivateKey::from_seed(Bytes::make(32, seed))
  let signature = fixture_hex(key.sign(@utf8.encode(canonical_json(value))))
  @utf8.encode(
    Json::object({
      "signed": value,
      "signatures": [{ "keyid": key_id, "sig": signature }],
    }).stringify(),
  )
}

///|
test "only authenticated online-key rotation permits recovery from fast-forwarded metadata" {
  for rotate in [false, true] {
    let trust = synthetic_tuf()
    ignore(trust.verify_timestamp(synthetic_timestamp(5000, 7000)))
    ignore(trust.verify_snapshot(synthetic_snapshot(7000, 9000)))
    let root = decode_json(@utf8.encode(trust.root.stringify()))
    guard root is Object(fields) &&
      fields.get("roles") is Some(Object(roles)) &&
      fields.get("keys") is Some(Object(keys)) else {
      fail("root fixture")
    }
    fields["version"] = Json(2)
    if rotate {
      let key = @ed25519.PrivateKey::from_seed(Bytes::make(32, b'\x72'))
      keys["rotated"] = {
        "keytype": "ed25519",
        "scheme": "ed25519",
        "keyval": { "public": fixture_hex(key.public_key().to_bytes()) },
      }
      roles["timestamp"] = { "keyids": ["rotated"], "threshold": 1 }
    }
    trust.rotate_root(signed_test_metadata(root))
    if rotate {
      let next = required(decode_json(synthetic_timestamp(1, 1)), "signed")
      assert_true(
        try {
          ignore(trust.verify_timestamp(signed_test_metadata(next)))
          false
        } catch {
          _ => true
        },
      )
      assert_eq(
        trust.verify_timestamp(
          signed_test_metadata_with_key(next, b'\x72', "rotated"),
        ),
        1L,
      )
      assert_eq(trust.verify_snapshot(synthetic_snapshot(1, 1)), 1L)
    } else {
      assert_true(
        try {
          ignore(trust.verify_timestamp(synthetic_timestamp(1, 1)))
          false
        } catch {
          _ => true
        },
      )
    }
  }
}

///|
fn synthetic_tuf() -> TufTrust raise {
  let key = @ed25519.PrivateKey::from_seed(Bytes::make(32, b'\x71'))
  let role : Json = { "keyids": ["test"], "threshold": 1 }
  let root : Json = {
    "_type": "root",
    "version": 1,
    "expires": "2030-01-01T00:00:00Z",
    "consistent_snapshot": true,
    "keys": {
      "test": {
        "keytype": "ed25519",
        "scheme": "ed25519",
        "keyval": { "public": fixture_hex(key.public_key().to_bytes()) },
      },
    },
    "roles": {
      "root": role,
      "timestamp": role,
      "snapshot": role,
      "targets": role,
    },
  }
  TufTrust::new(
    signed_test_metadata(root),
    now_unix=timestamp("2026-10-21T00:00:00Z"),
  )
}

///|
fn synthetic_timestamp(version : Int32, snapshot : Int32) -> Bytes raise {
  signed_test_metadata({
    "_type": "timestamp",
    "version": version,
    "expires": "2029-01-01T00:00:00Z",
    "meta": { "snapshot.json": { "version": snapshot } },
  })
}

///|
fn synthetic_snapshot(version : Int32, targets : Int32) -> Bytes raise {
  signed_test_metadata({
    "_type": "snapshot",
    "version": version,
    "expires": "2029-01-01T00:00:00Z",
    "meta": { "targets.json": { "version": targets } },
  })
}

///|
test "validly signed TUF rollback and same-version mutation are rejected without poisoning state" {
  let trust = synthetic_tuf()
  ignore(trust.verify_timestamp(synthetic_timestamp(5, 7)))
  ignore(trust.verify_snapshot(synthetic_snapshot(7, 9)))
  let target : Json = {
    "_type": "targets",
    "version": 9,
    "expires": "2029-01-01T00:00:00Z",
    "targets": {
      "trusted_root.json": {
        "length": 2,
        "hashes": { "sha256": fixture_hex(@hash.sha256(b"{}")) },
      },
    },
  }
  trust.verify_targets(signed_test_metadata(target))
  for
    bytes in [
      synthetic_timestamp(4, 7),
      synthetic_timestamp(6, 6),
      synthetic_timestamp(5, 8),
    ] {
    assert_true(
      try {
        ignore(trust.verify_timestamp(bytes))
        false
      } catch {
        _ => true
      },
    )
    assert_eq(
      trust.verify_target("trusted_root.json", b"{}"),
      Json::empty_object(),
    )
  }
  ignore(trust.verify_timestamp(synthetic_timestamp(6, 8)))
  assert_true(
    try {
      ignore(trust.verify_snapshot(synthetic_snapshot(8, 8)))
      false
    } catch {
      Invalid(message) => message == "TUF delegated metadata rollback"
      _ => false
    },
  )
  ignore(trust.verify_snapshot(synthetic_snapshot(8, 9)))
  let changed : Json = {
    "_type": "targets",
    "version": 9,
    "expires": "2029-01-02T00:00:00Z",
    "targets": {
      "trusted_root.json": {
        "length": 2,
        "hashes": { "sha256": fixture_hex(@hash.sha256(b"{}")) },
      },
    },
  }
  assert_true(
    try {
      trust.verify_targets(signed_test_metadata(changed))
      false
    } catch {
      _ => true
    },
  )
  trust.verify_targets(signed_test_metadata(target))
  assert_eq(
    trust.verify_target("trusted_root.json", b"{}"),
    Json::empty_object(),
  )
}
