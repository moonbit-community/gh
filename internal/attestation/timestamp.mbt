///|
/// The dependency's CMS API handles detached id-data only. RFC 3161 instead
/// embeds TSTInfo, and GitHub supplies TSA certificates in the trusted root.
/// This adapter uses its ASN.1, X.509 and signature primitives, never its
/// detached-content assumptions. Protocol: RFC 3161/5652/5816.
priv struct TimestampToken {
  unix_time : Int64
  nanosecond : Int32
  certificate_time : String
  certificate_upper_time : String
  upper_unix_time : Int64
  text_time : String
  issuer : Bytes
  serial : Bytes
  signed_attributes : Bytes
  signature_algorithm : @pkix.AlgorithmIdentifier
  signature : Bytes
  signing_certificate : @asn1.Element?
  signing_certificate_v2 : @asn1.Element?
  embedded_certificates : Array[Bytes]
}

///|
fn signed_attributes(
  element : @asn1.Element,
) -> (Bytes, Map[String, @asn1.Element]) raise VerificationError {
  let raw = context_bytes(element, 0)
  let values = @asn1.decode_der_all(raw) catch {
    _ => raise Invalid("invalid timestamp signed attributes")
  }
  guard !values.is_empty() && values.length() <= 32 else {
    raise Invalid("invalid signed attribute count")
  }
  let attributes : Map[String, @asn1.Element] = Map([])
  let mut previous : Bytes? = None
  for entry in values {
    let encoded = @asn1.encode_der(entry)
    if previous is Some(prev) {
      // DER SET OF ordering compares complete encodings lexicographically.
      guard byte_order(prev, encoded) < 0 else {
        raise Invalid("noncanonical timestamp signed attributes")
      }
    }
    previous = Some(encoded)
    let pair = sequence(entry)
    guard pair.length() == 2 else {
      raise Invalid("invalid timestamp attribute")
    }
    let name = oid(pair[0])
    guard !attributes.contains(name) else {
      raise Invalid("duplicate timestamp signed attribute")
    }
    let values = set_values(pair[1])
    guard values.length() == 1 else {
      raise Invalid("timestamp signed attribute must have one value")
    }
    attributes[name] = values[0]
  }
  // SignedAttrs is signed with universal SET tag, not the implicit [0] tag.
  let encoded = @asn1.encode_der(@asn1.Element::new(@asn1.tag_set, Set(values)))
  let original = @asn1.encode_der(element)
  guard encoded.length() == original.length() && encoded[1:] == original[1:] else {
    raise Invalid("noncanonical timestamp signed attribute encoding")
  }
  (encoded, attributes)
}

///|
fn byte_order(a : Bytes, b : Bytes) -> Int32 {
  for i in 0..<a.length().min(b.length()) {
    if a[i] != b[i] {
      return a[i].compare(b[i])
    }
  }
  a.length().compare(b.length())
}

///|
fn timestamp_token(
  bytes : Bytes,
  signature : Bytes,
) -> TimestampToken raise VerificationError {
  let response = sequence(der(bytes))
  guard response.length() == 2 else {
    raise Invalid("invalid timestamp response")
  }
  let status = sequence(response[0])
  guard !status.is_empty() else { raise Invalid("missing timestamp status") }
  let status = integer_bytes(status[0])
  guard status == b"\x00" || status == b"\x01" else {
    raise Invalid("timestamp request was not granted")
  }
  let content = sequence(response[1])
  guard content.length() == 2 && oid(content[0]) == "1.2.840.113549.1.7.2" else {
    raise Invalid("expected timestamp SignedData")
  }
  let data = sequence(der(context_bytes(content[1], 0)))
  guard data.length() >= 4 &&
    data.length() <= 6 &&
    integer_bytes(data[0]) == b"\x03" else {
    raise Invalid("invalid timestamp SignedData structure")
  }
  let algorithms = set_values(data[1])
  guard algorithms.length() == 1 else {
    raise Invalid("timestamp must have one digest algorithm")
  }
  let digest_id = digest_algorithm(algorithms[0])
  let encapsulated = sequence(data[2])
  guard encapsulated.length() == 2 &&
    oid(encapsulated[0]) == "1.2.840.113549.1.9.16.1.4" else {
    raise Invalid("timestamp content is not TSTInfo")
  }
  let tst_bytes = octets(der(context_bytes(encapsulated[1], 0)))
  let tst = sequence(der(tst_bytes))
  guard tst.length() >= 5 &&
    tst.length() <= 10 &&
    integer_bytes(tst[0]) == b"\x01" else {
    raise Invalid("invalid TSTInfo structure")
  }
  ignore(oid(tst[1])) // Policy is signed; no specific policy OID is required by gh.
  ignore(integer_bytes(tst[3]))
  let imprint = sequence(tst[2])
  guard imprint.length() == 2 else {
    raise Invalid("invalid timestamp message imprint")
  }
  let imprint_hash = digest(digest_algorithm(imprint[0]), signature)
  guard @hash.ct_eq(imprint_hash, octets(imprint[1])) else {
    raise Invalid("timestamp does not bind to the bundle signature")
  }
  guard tst[4].value is GeneralizedTime(time) else {
    raise Invalid("missing timestamp generation time")
  }
  let (unix_time, certificate_time) = generalized_time(time)
  let nanosecond = if time.contains(".") {
    let fraction = time.split_once(".").unwrap().1
      .strip_suffix("Z")
      .unwrap()
      .to_owned()
    guard fraction.length() <= 9 else {
      raise Invalid("unsupported timestamp precision")
    }
    @string.parse_int(fraction + String::make(9 - fraction.length(), '0')) catch {
      _ => raise Invalid("invalid timestamp fraction")
    }
  } else {
    0
  }
  let upper_unix_time = unix_time + (if time.contains(".") { 1L } else { 0L })
  let certificate_upper_time = if time.contains(".") {
    let upper = @time.PlainDateTime::from_unix_second(
      upper_unix_time,
      0,
      @time.ZoneOffset::from_seconds(0),
    ) catch {
      _ => raise Invalid("timestamp time overflow")
    }
    upper
    .to_string()
    .replace_all(old="-", new="")
    .replace_all(old=":", new="")
    .replace_all(old="T", new="") +
    "Z"
  } else {
    certificate_time
  }
  // Validate optional fields in their schema order; unknown extensions fail
  // closed rather than treating an unrecognized restriction as verified.
  let mut optional_index = 5
  if optional_index < tst.length() &&
    tst[optional_index].tag == @asn1.tag_sequence {
    let accuracy = sequence(tst[optional_index])
    let mut previous = -1
    for part in accuracy {
      let order = if part.tag == @asn1.tag_integer {
        0
      } else if part.tag == @asn1.Tag::context(0) {
        1
      } else if part.tag == @asn1.Tag::context(1) {
        2
      } else {
        raise Invalid("invalid timestamp accuracy")
      }
      guard order > previous else {
        raise Invalid("invalid timestamp accuracy order")
      }
      previous = order
    }
    optional_index += 1
  }
  if optional_index < tst.length() &&
    tst[optional_index].tag == @asn1.tag_boolean {
    guard tst[optional_index].value is Boolean(true) else {
      raise Invalid("noncanonical timestamp ordering default")
    }
    optional_index += 1
  }
  if optional_index < tst.length() &&
    tst[optional_index].tag == @asn1.tag_integer {
    ignore(integer_bytes(tst[optional_index]))
    optional_index += 1
  }
  if optional_index < tst.length() &&
    tst[optional_index].tag == @asn1.Tag::context(0, constructed=true) {
    ignore(der(context_bytes(tst[optional_index], 0)))
    optional_index += 1
  }
  guard optional_index == tst.length() else {
    raise Invalid("unsupported timestamp extension")
  }
  let embedded : Array[Bytes] = []
  let mut signer_index = 3
  if data[signer_index].tag == @asn1.Tag::context(0, constructed=true) {
    let certificates = @asn1.decode_der_all(
      context_bytes(data[signer_index], 0),
    ) catch {
      _ => raise Invalid("invalid embedded timestamp certificates")
    }
    guard certificates.length() <= 10 else {
      raise Invalid("too many timestamp certificates")
    }
    for cert in certificates {
      let raw = @asn1.encode_der(cert)
      ignore(certificate(raw))
      embedded.push(raw)
    }
    signer_index += 1
  }
  guard signer_index == data.length() - 1 else {
    raise Invalid("unsupported timestamp revocation information")
  }
  let signers = set_values(data[signer_index])
  guard signers.length() == 1 else {
    raise Invalid("timestamp must have one signer")
  }
  let signer = sequence(signers[0])
  guard (signer.length() == 6 || signer.length() == 7) &&
    integer_bytes(signer[0]) == b"\x01" else {
    raise Invalid("invalid timestamp SignerInfo")
  }
  let sid = sequence(signer[1])
  guard sid.length() == 2 else {
    raise Invalid("invalid timestamp signer identifier")
  }
  ignore(sequence(sid[0]))
  let serial = integer_bytes(sid[1])
  guard digest_algorithm(signer[2]) == digest_id else {
    raise Invalid("timestamp digest algorithms disagree")
  }
  let (signed_attributes, attributes) = signed_attributes(signer[3])
  guard attributes.get("1.2.840.113549.1.9.3") is Some(content_type) &&
    oid(content_type) == "1.2.840.113549.1.9.16.1.4" else {
    raise Invalid("timestamp signed content type mismatch")
  }
  guard attributes.get("1.2.840.113549.1.9.4") is Some(message_digest) &&
    @hash.ct_eq(octets(message_digest), digest(digest_id, tst_bytes)) else {
    raise Invalid("timestamp signed content digest mismatch")
  }
  let sig_alg = algorithm(signer[4])
  let signature_digest = match sig_alg.algorithm.to_string() {
    "1.2.840.10045.4.3.2" | "1.2.840.113549.1.1.11" => "2.16.840.1.101.3.4.2.1"
    "1.2.840.10045.4.3.3" | "1.2.840.113549.1.1.12" => "2.16.840.1.101.3.4.2.2"
    "1.2.840.10045.4.3.4" | "1.2.840.113549.1.1.13" => "2.16.840.1.101.3.4.2.3"
    _ => raise Invalid("unsupported timestamp signature algorithm")
  }
  guard signature_digest == digest_id else {
    raise Invalid("timestamp signature and digest algorithms disagree")
  }
  if signer.length() == 7 {
    ignore(context_bytes(signer[6], 1))
  }
  let binding = attributes.get("1.2.840.113549.1.9.16.2.12")
  let binding_v2 = attributes.get("1.2.840.113549.1.9.16.2.47")
  guard binding is Some(_) || binding_v2 is Some(_) else {
    raise Invalid("timestamp lacks signing certificate binding")
  }
  {
    unix_time,
    nanosecond,
    certificate_time,
    certificate_upper_time,
    upper_unix_time,
    text_time: time[:4].to_owned() +
    "-" +
    time[4:6].to_owned() +
    "-" +
    time[6:8].to_owned() +
    "T" +
    time[8:10].to_owned() +
    ":" +
    time[10:12].to_owned() +
    ":" +
    time[12:].to_owned(),
    issuer: @asn1.encode_der(sid[0]),
    serial,
    signed_attributes,
    signature_algorithm: sig_alg,
    signature: octets(signer[5]),
    signing_certificate: binding,
    signing_certificate_v2: binding_v2,
    embedded_certificates: embedded,
  }
}

///|
fn verify_certificate_binding(
  element : @asn1.Element,
  cert : @pkix.Certificate,
  raw : Bytes,
  v2 : Bool,
) -> Unit raise VerificationError {
  let structure = sequence(element)
  guard structure.length() >= 1 && structure.length() <= 2 else {
    raise Invalid("invalid signing certificate binding")
  }
  let bindings = sequence(structure[0])
  guard !bindings.is_empty() && bindings.length() <= 10 else {
    raise Invalid("invalid signing certificate binding count")
  }
  let binding = sequence(bindings[0])
  guard !binding.is_empty() else {
    raise Invalid("missing signing certificate digest")
  }
  let mut index = 0
  let digest_id = if v2 {
    if binding[0].tag == @asn1.tag_sequence {
      index = 1
      digest_algorithm(binding[0])
    } else {
      "2.16.840.1.101.3.4.2.1"
    }
  } else {
    "1.3.14.3.2.26"
  }
  guard binding.length() == index + 1 || binding.length() == index + 2 else {
    raise Invalid("invalid signing certificate fields")
  }
  let expected = if v2 { digest(digest_id, raw) } else { @hash.sha1(raw) }
  guard @hash.ct_eq(expected, octets(binding[index])) else {
    raise Invalid("timestamp signing certificate digest mismatch")
  }
  if binding.length() == index + 2 {
    let issuer_serial = sequence(binding[index + 1])
    guard issuer_serial.length() == 2 &&
      integer_bytes(issuer_serial[1]) == cert.tbs.serial_number else {
      raise Invalid("timestamp signing certificate serial mismatch")
    }
    let names = sequence(issuer_serial[0])
    let issuer = @pkix.serialize_name(cert.tbs.issuer)
    let mut matches = false
    for name in names {
      if name.tag == @asn1.Tag::context(4, constructed=true) &&
        context_bytes(name, 4) == issuer {
        matches = true
      }
    }
    guard matches else {
      raise Invalid("timestamp signing certificate issuer mismatch")
    }
  }
}

///|
fn verify_timestamp_authority(
  token : TimestampToken,
  authority : Authority,
) -> Unit raise VerificationError {
  guard authority.valid_at(token.unix_time, nanosecond=token.nanosecond) &&
    authority.certificates.length() >= 2 else {
    raise Invalid("timestamp authority is outside its trust period")
  }
  let certificates = authority.certificates
  let leaf = certificates[0]
  let raw = authority.certificate_bytes[0]
  guard @pkix.serialize_name(leaf.tbs.issuer) == token.issuer &&
    leaf.tbs.serial_number == token.serial else {
    raise Invalid("timestamp signer does not match authority")
  }
  if !token.embedded_certificates.is_empty() {
    guard token.embedded_certificates.contains(raw) else {
      raise Invalid("embedded timestamp signer differs from trusted authority")
    }
  }
  if token.signing_certificate is Some(binding) {
    verify_certificate_binding(binding, leaf, raw, false)
  }
  if token.signing_certificate_v2 is Some(binding) {
    verify_certificate_binding(binding, leaf, raw, true)
  }
  verify_chain(
    leaf,
    certificates[1:certificates.length() - 1].to_owned(),
    certificates[certificates.length() - 1],
    token.certificate_time,
    "1.3.6.1.5.5.7.3.8",
  )
  if token.certificate_upper_time != token.certificate_time {
    verify_chain(
      leaf,
      certificates[1:certificates.length() - 1].to_owned(),
      certificates[certificates.length() - 1],
      token.certificate_upper_time,
      "1.3.6.1.5.5.7.3.8",
    )
  }
  let key = @pkix_verify.extract_public_key(leaf.tbs.subject_public_key_info) catch {
    _ => raise Invalid("unsupported timestamp signing key")
  }
  @pkix_verify.verify_signature(
    token.signed_attributes,
    token.signature_algorithm,
    { bytes: token.signature, unused_bits: 0, },
    key,
  ) catch {
    _ => raise Invalid("timestamp signature verification failed")
  }
}
