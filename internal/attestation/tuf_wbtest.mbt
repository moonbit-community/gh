///|
test "TUF canonical JSON uses scalar key order and literal PEM line breaks" {
  let value : Json = { "z": "a\nb\\\"", "aa": 1, "😀": true, "\uE000": false }
  assert_eq(
    canonical_json(value),
    "{\"aa\":1,\"z\":\"a\nb\\\\\\\"\",\"\uE000\":false,\"😀\":true}",
  )
  assert_true(
    try {
      ignore(canonical_json(@json.parse("1.5")))
      false
    } catch {
      _ => true
    },
  )
}

///|
test "GitHub public TUF root rotation and target chain verify with tampering rejected" {
  let trust = TufTrust::new(
    trust_fixture("bootstrap-root.json"),
    now_unix=timestamp("2026-10-21T00:00:00Z"),
  )
  assert_eq(trust.root_version(), 3L)
  // A valid later root may not skip the intervening cross-signed root.
  assert_true(
    try {
      trust.rotate_root(trust_fixture("5.root.json"))
      false
    } catch {
      _ => true
    },
  )
  assert_eq(trust.root_version(), 3L)
  for version in 4..<=9 {
    trust.rotate_root(trust_fixture("\{version}.root.json"))
  }
  assert_eq(trust.root_version(), 9L)
  let timestamp_bytes = trust_fixture("timestamp.json")
  assert_eq(trust.verify_timestamp(timestamp_bytes), 81L)
  assert_true(
    try {
      ignore(trust.target_filename("trusted_root.json"))
      false
    } catch {
      _ => true
    },
  )
  assert_eq(trust.verify_snapshot(trust_fixture("81.snapshot.json")), 10L)
  trust.verify_targets(trust_fixture("10.targets.json"))
  let target = "484cdfe1a7c65479c5ba2a22193d1be90f0020db1997de696ab207434c62fbb7.trusted_root.json"
  assert_eq(trust.target_filename("trusted_root.json"), target)
  let bytes = trust_fixture("targets__" + target)
  let verified = trust.verify_target("trusted_root.json", bytes)
  assert_eq(
    required_string(verified, "mediaType"),
    "application/vnd.dev.sigstore.trustedroot+json;version=0.1",
  )
  assert_true(
    try {
      ignore(trust.verify_target("trusted_root.json", bytes + b" "))
      false
    } catch {
      _ => true
    },
  )
  // Editing any signed metadata fails without replacing the accepted state.
  let altered = @utf8.encode(
    @utf8.decode(timestamp_bytes).replace_all(old="994", new="995"),
  )
  assert_true(
    try {
      ignore(trust.verify_timestamp(altered))
      false
    } catch {
      _ => true
    },
  )
  assert_eq(trust.target_filename("trusted_root.json"), target)
  // A successfully refreshed timestamp invalidates downstream verification.
  ignore(trust.verify_timestamp(timestamp_bytes))
  assert_true(
    try {
      ignore(trust.verify_target("trusted_root.json", bytes))
      false
    } catch {
      _ => true
    },
  )
  assert_true(
    try {
      trust.rotate_root(trust_fixture("9.root.json"))
      false
    } catch {
      _ => true
    },
  )
}

///|
test "expired GitHub bootstrap cannot authorize timestamp without root rotation" {
  let trust = TufTrust::new(
    trust_fixture("bootstrap-root.json"),
    now_unix=timestamp("2026-10-21T00:00:00Z"),
  )
  assert_true(
    try {
      ignore(trust.verify_timestamp(trust_fixture("timestamp.json")))
      false
    } catch {
      _ => true
    },
  )
}

///|
test "restored expired metadata sets rollback floors but never authorizes targets" {
  let trust = TufTrust::new(
    trust_fixture("bootstrap-root.json"),
    now_unix=timestamp("2026-10-28T00:00:00Z"),
  )
  for version in 4..<=9 {
    trust.rotate_root(trust_fixture("\{version}.root.json"))
  }
  trust.restore_previous(
    trust_fixture("timestamp.json"),
    trust_fixture("81.snapshot.json"),
    trust_fixture("10.targets.json"),
  )
  assert_true(
    try {
      ignore(trust.target_filename("trusted_root.json"))
      false
    } catch {
      _ => true
    },
  )
  assert_true(
    try {
      ignore(trust.verify_timestamp(trust_fixture("timestamp.json")))
      false
    } catch {
      Invalid(message) => message == "expired TUF metadata"
    },
  )
}
