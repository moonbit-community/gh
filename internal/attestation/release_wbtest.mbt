///|
fn github_material() -> TrustedMaterial raise VerificationError {
  TrustedMaterial::from_custom_root(
    trust_fixture(
      "targets__484cdfe1a7c65479c5ba2a22193d1be90f0020db1997de696ab207434c62fbb7.trusted_root.json",
    ),
  )
}

///|
test "trust authority fractional validity neither rounds early nor rejects later valid timestamps" {
  let (start, start_nanosecond) = timestamp_parts("2026-10-21T00:00:00.25Z")
  let (end, end_nanosecond) = timestamp_parts("2026-10-21T00:00:00.75Z")
  let authority : Authority = {
    uri: "fixture",
    certificates: [],
    certificate_bytes: [],
    start,
    start_nanosecond,
    end: Some(end),
    end_nanosecond,
  }
  assert_false(authority.valid_at(start))
  assert_false(authority.valid_at(start, nanosecond=249999999))
  assert_true(authority.valid_at(start, nanosecond=250000000))
  assert_true(authority.valid_at(start, nanosecond=500000000))
  assert_true(authority.valid_at(end, nanosecond=750000000))
  assert_false(authority.valid_at(end, nanosecond=750000001))
}

///|
test "real CLI v2.102.0 Release v0.2 proof verifies against captured trust material" {
  let verified = github_material().verify_release(
    public_release_fixture(),
    tag="v2.102.0",
    ref_digest="sha1:fc4b137cdef0a6bd28fd461b7cf9c84a5812a8cd",
    asset_sha256="afe49e9affa232faa8212aed035417166f6ade9b9470acb53d4dbd28c0504e8d",
    now_unix=timestamp("2026-10-21T00:00:00Z"),
  ) catch {
    Invalid(detail) => fail(detail)
  }
  assert_eq(
    required_string(verified.statement(), "predicateType"),
    "https://in-toto.io/attestation/release/v0.2",
  )
}

///|
test "GitHub release fixture verifies signed timestamp and release binding after certificate expiry" {
  let verified = github_material().verify_release(
    trust_fixture("github-release-bundle.json"),
    tag="v6",
    ref_digest="sha1:c5e17a62e06a1d201570249c61fae531e9244e1b",
    asset_sha256="e15b593c6ab8d7725a3cc82226ef816cac6bf9c70eed383bd459295cc65f5ec3",
    now_unix=timestamp("2026-10-21T00:00:00Z"),
  ) catch {
    Invalid(detail) => fail(detail)
  }
  assert_eq(verified.signed_at(), timestamp("2025-05-30T20:13:39Z"))
  assert_eq(
    required_string(required(verified.statement(), "predicate"), "tag"),
    "v6",
  )
}

///|
test "release timestamp fixture authenticates independently before envelope integration" {
  let bundle = decode_json(trust_fixture("github-release-bundle.json"))
  let envelope = required(bundle, "dsseEnvelope")
  let signature = base64_bytes(
    required_string(required_array(envelope, "signatures")[0], "sig"),
  )
  let material = required(bundle, "verificationMaterial")
  let ts = required_array(
      required(material, "timestampVerificationData"),
      "rfc3161Timestamps",
    )[0]
  let token = timestamp_token(
    base64_bytes(required_string(ts, "signedTimestamp")),
    signature,
  ) catch {
    Invalid(detail) => fail(detail)
  }
  let trust = github_material()
  let authority = trust.timestamp_authorities
    .iter()
    .filter(authority => {
      authority.valid_at(token.unix_time) &&
      @pkix.serialize_name(authority.certificates[0].tbs.issuer) == token.issuer &&
      authority.certificates[0].tbs.serial_number == token.serial
    })
    .next()
    .unwrap()
  let chain = authority.certificates
  @pkix_verify.verify_chain_for_signature_with_anchor_cert(
    chain[0],
    chain[1:chain.length() - 1].to_owned(),
    chain[chain.length() - 1],
    token.certificate_time,
    opts={
      required_eku: Some(
        @asn1.ObjectIdentifier::from_string("1.3.6.1.5.5.7.3.8"),
      ),
      required_policy: None,
    },
  ) catch {
    err => fail(@debug.to_string(err))
  }
  verify_timestamp_authority(token, authority) catch {
    Invalid(detail) => fail(detail)
  }
}
