///|
test "critical EKU requires explicit matching purpose throughout certificate verification" {
  let ca_seed = "5151515151515151515151515151515151515151515151515151515151510a01"
  let leaf_seed = "5151515151515151515151515151515151515151515151515151515151510a02"
  let timestamping = @asn1.ObjectIdentifier::from_string("1.3.6.1.5.5.7.3.8")
  let code_signing = @asn1.ObjectIdentifier::from_string("1.3.6.1.5.5.7.3.3")
  let eku : @pkix.Extension = {
    oid: @asn1.ObjectIdentifier::from_string("2.5.29.37"),
    critical: true,
    value: @asn1.encode_der(
      @asn1.Element::new(
        @asn1.tag_sequence,
        Sequence([@asn1.Element::new(@asn1.tag_oid, Oid(timestamping))]),
      ),
    ),
  }
  let (root, _) = build_self_signed_ed25519(
    ca_seed,
    "TSA Root",
    "250101000000Z",
    "260101000000Z",
    [basic_constraints_ca_ext(), key_usage_ext(true, true)],
  )
  let (leaf, _) = build_ed25519_cert(
    leaf_seed,
    "TSA",
    "TSA Root",
    "250101000000Z",
    "260101000000Z",
    [eku],
    ca_seed,
  )
  @pkix_verify.verify_chain_for_signature_with_anchor_cert(
    leaf,
    [],
    root,
    "250601000000Z",
    opts={ required_eku: Some(timestamping), required_policy: None, },
  )
  assert_true(
    try {
      @pkix_verify.verify_chain_for_signature_with_anchor_cert(
        leaf,
        [],
        root,
        "250601000000Z",
      )
      false
    } catch {
      UnknownCriticalExtension(_) => true
      _ => false
    },
  )
  assert_true(
    try {
      @pkix_verify.verify_chain_for_signature_with_anchor_cert(
        leaf,
        [],
        root,
        "250601000000Z",
        opts={ required_eku: Some(code_signing), required_policy: None, },
      )
      false
    } catch {
      ExtendedKeyUsageMissing(_) => true
      _ => false
    },
  )
}
