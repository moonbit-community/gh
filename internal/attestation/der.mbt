///|
fn base64_bytes(text : String) -> Bytes raise VerificationError {
  guard text.length() <= 14000000 else {
    raise Invalid("base64 verification input exceeds size limit")
  }
  @base64.decode(text) catch {
    _ => raise Invalid("invalid base64 verification input")
  }
}

///|
fn der(bytes : Bytes) -> @asn1.Element raise VerificationError {
  guard bytes.length() <= 524288 else {
    raise Invalid("DER verification input exceeds size limit")
  }
  @asn1.decode_der(bytes) catch {
    _ => raise Invalid("invalid DER verification input")
  }
}

///|
fn sequence(
  element : @asn1.Element,
) -> Array[@asn1.Element] raise VerificationError {
  guard element.value is Sequence(values) else {
    raise Invalid("expected ASN.1 sequence")
  }
  values
}

///|
fn set_values(
  element : @asn1.Element,
) -> Array[@asn1.Element] raise VerificationError {
  guard element.value is Set(values) else {
    raise Invalid("expected ASN.1 set")
  }
  values
}

///|
fn octets(element : @asn1.Element) -> Bytes raise VerificationError {
  guard element.value is OctetString(bytes) else {
    raise Invalid("expected ASN.1 octet string")
  }
  bytes
}

///|
fn integer_bytes(element : @asn1.Element) -> Bytes raise VerificationError {
  guard element.value is Integer(bytes) && !bytes.is_empty() && bytes[0] < 128 else {
    raise Invalid("expected nonnegative ASN.1 integer")
  }
  bytes
}

///|
fn oid(element : @asn1.Element) -> String raise VerificationError {
  guard element.value is Oid(value) else {
    raise Invalid("expected ASN.1 object identifier")
  }
  value.to_string()
}

///|
fn context_bytes(
  element : @asn1.Element,
  tag : UInt32,
) -> Bytes raise VerificationError {
  guard element.tag == @asn1.Tag::context(tag, constructed=true) &&
    element.value is Unknown(bytes) else {
    raise Invalid("unexpected ASN.1 context tag")
  }
  bytes
}

///|
fn algorithm(
  element : @asn1.Element,
) -> @pkix.AlgorithmIdentifier raise VerificationError {
  @pkix.parse_algorithm_identifier_elem(element) catch {
    _ => raise Invalid("invalid signature algorithm")
  }
}

///|
fn digest_algorithm(element : @asn1.Element) -> String raise VerificationError {
  let alg = algorithm(element)
  guard alg.parameters is None || alg.parameters == Some(b"\x05\x00") else {
    raise Invalid("invalid digest algorithm parameters")
  }
  let id = alg.algorithm.to_string()
  guard id == "2.16.840.1.101.3.4.2.1" ||
    id == "2.16.840.1.101.3.4.2.2" ||
    id == "2.16.840.1.101.3.4.2.3" else {
    raise Invalid("unsupported or weak timestamp digest algorithm")
  }
  id
}

///|
fn digest(algorithm : String, bytes : Bytes) -> Bytes raise VerificationError {
  match algorithm {
    "2.16.840.1.101.3.4.2.1" => @hash.sha256(bytes)
    "2.16.840.1.101.3.4.2.2" => @hash.sha384(bytes)
    "2.16.840.1.101.3.4.2.3" => @hash.sha512(bytes)
    _ => raise Invalid("unsupported or weak timestamp digest algorithm")
  }
}

///|
fn certificate(bytes : Bytes) -> @pkix.Certificate raise VerificationError {
  guard bytes.length() <= 65536 else {
    raise Invalid("certificate exceeds size limit")
  }
  @pkix.parse_certificate(bytes) catch {
    _ => raise Invalid("invalid certificate")
  }
}

///|
fn required_array(
  value : Json,
  key : String,
) -> Array[Json] raise VerificationError {
  guard required(value, key) is Array(values) else {
    raise Invalid("expected verification metadata array")
  }
  values
}

///|
fn optional(value : Json, key : String) -> Json? {
  match value {
    Object(fields) => fields.get(key)
    _ => None
  }
}

///|
/// RFC 3161 uses UTC GeneralizedTime, with optional fractional seconds.
/// Certificates have second precision; preserve the signed timestamp string
/// separately while using its floor only for certificate-validity checks.
fn generalized_time(text : String) -> (Int64, String) raise VerificationError {
  guard text.strip_suffix("Z") is Some(body) && body.length() >= 14 else {
    raise Invalid("invalid timestamp time")
  }
  let whole = body[:14].to_owned()
  for c in whole {
    guard c >= '0' && c <= '9' else { raise Invalid("invalid timestamp time") }
  }
  if body.length() > 14 {
    let suffix = body[14:].to_owned()
    guard suffix.has_prefix(".") &&
      suffix.length() > 1 &&
      !suffix.has_suffix("0") else {
      raise Invalid("noncanonical timestamp fraction")
    }
    for c in suffix[1:] {
      guard c >= '0' && c <= '9' else {
        raise Invalid("invalid timestamp fraction")
      }
    }
  }
  let iso = whole[:4].to_owned() +
    "-" +
    whole[4:6].to_owned() +
    "-" +
    whole[6:8].to_owned() +
    "T" +
    whole[8:10].to_owned() +
    ":" +
    whole[10:12].to_owned() +
    ":" +
    whole[12:14].to_owned() +
    "Z"
  (timestamp(iso), whole + "Z")
}
