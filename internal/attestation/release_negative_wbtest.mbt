///|
fn set_json(value : Json, key : String, replacement : Json) -> Unit raise {
  guard value is Object(fields) else { fail("expected test fixture object") }
  fields[key] = replacement
}

///|
fn rejects_release(bundle : Json, material : TrustedMaterial) -> Bool {
  try {
    ignore(
      material.verify_release(
        @utf8.encode(bundle.stringify()),
        tag="v6",
        ref_digest="sha1:c5e17a62e06a1d201570249c61fae531e9244e1b",
        now_unix=1792540800L,
      ),
    )
    false
  } catch {
    _ => true
  }
}

///|
test "release proof rejects independently altered payload signature certificate and timestamp" {
  let trust = github_material()
  for field in ["payload", "signature", "certificate", "timestamp"] {
    let bundle = decode_json(trust_fixture("github-release-bundle.json"))
    let envelope = required(bundle, "dsseEnvelope")
    let material = required(bundle, "verificationMaterial")
    let (object, key) = match field {
      "payload" => (envelope, "payload")
      "signature" => (required_array(envelope, "signatures")[0], "sig")
      "certificate" => (required(material, "certificate"), "rawBytes")
      _ =>
        (
          required_array(
            required(material, "timestampVerificationData"),
            "rfc3161Timestamps",
          )[0],
          "signedTimestamp",
        )
    }
    let original = base64_bytes(required_string(object, key))
    let corrupted = Bytes::makei(original.length(), i => {
      if i == original.length() - 1 {
        (original[i].to_int() ^ 1).to_byte()
      } else {
        original[i]
      }
    })
    set_json(object, key, Json(@base64.encode(corrupted)))
    assert_true(
      rejects_release(bundle, trust),
      msg="tampered " + field + " was accepted",
    )
  }
  let bundle = decode_json(trust_fixture("github-release-bundle.json"))
  set_json(
    required(
      required(bundle, "verificationMaterial"),
      "timestampVerificationData",
    ),
    "rfc3161Timestamps",
    Json::array([]),
  )
  assert_true(rejects_release(bundle, trust))
}

///|
test "valid signed release cannot authorize a different tag ref asset or future verification time" {
  let trust = github_material()
  let bundle = trust_fixture("github-release-bundle.json")
  for
    (tag, ref_digest, asset, now) in [
      ("v7", "sha1:c5e17a62e06a1d201570249c61fae531e9244e1b", None, 1792540800L),
      ("v6", "sha1:0000000000000000000000000000000000000000", None, 1792540800L),
      (
        "v6",
        "sha1:c5e17a62e06a1d201570249c61fae531e9244e1b",
        Some("0000000000000000000000000000000000000000000000000000000000000000"),
        1792540800L,
      ),
      ("v6", "sha1:c5e17a62e06a1d201570249c61fae531e9244e1b", None, 1700000000L),
    ] {
    assert_true(
      try {
        ignore(
          trust.verify_release(
            bundle,
            tag~,
            ref_digest~,
            asset_sha256?=asset,
            now_unix=now,
          ),
        )
        false
      } catch {
        _ => true
      },
    )
  }
}

///|
test "removing trusted signing or timestamp authorities never downgrades verification" {
  for field in ["certificateAuthorities", "timestampAuthorities"] {
    let root = decode_json(
      trust_fixture(
        "targets__484cdfe1a7c65479c5ba2a22193d1be90f0020db1997de696ab207434c62fbb7.trusted_root.json",
      ),
    )
    set_json(root, field, Json::array([]))
    let trust = TrustedMaterial::from_custom_root(
      @utf8.encode(root.stringify()),
    )
    assert_true(
      rejects_release(
        decode_json(trust_fixture("github-release-bundle.json")),
        trust,
      ),
    )
  }
}

///|
test "RFC3161 imprint binds to exact DSSE signature and rejects trailing DER" {
  let bundle = decode_json(trust_fixture("github-release-bundle.json"))
  let signature = base64_bytes(
    required_string(
      required_array(required(bundle, "dsseEnvelope"), "signatures")[0],
      "sig",
    ),
  )
  let timestamps = required_array(
    required(
      required(bundle, "verificationMaterial"),
      "timestampVerificationData",
    ),
    "rfc3161Timestamps",
  )
  let bytes = base64_bytes(required_string(timestamps[0], "signedTimestamp"))
  assert_true(
    try {
      ignore(timestamp_token(bytes, signature + b"changed"))
      false
    } catch {
      Invalid(detail) =>
        detail == "timestamp does not bind to the bundle signature"
    },
  )
  assert_true(
    try {
      ignore(timestamp_token(bytes + b"\x00", signature))
      false
    } catch {
      _ => true
    },
  )
}

///|
test "verification metadata bounds nesting before recursive schema or canonical processing" {
  let text = String::make(65, '[') + "0" + String::make(65, ']')
  assert_true(
    try {
      ignore(decode_json(@utf8.encode(text)))
      false
    } catch {
      _ => true
    },
  )
  assert_eq(decode_json(b"{\"ok\":[1,2]}"), Json::object({ "ok": [1, 2] }))
}
