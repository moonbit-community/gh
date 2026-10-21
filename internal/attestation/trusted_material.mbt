///|
struct Authority {
  uri : String
  certificates : Array[@pkix.Certificate]
  certificate_bytes : Array[Bytes]
  start : Int64
  start_nanosecond : Int32
  end : Int64?
  end_nanosecond : Int32
}

///|
/// Caller-supplied trust is an explicit offline trust decision. Network
/// material must instead come from TufTrust::trusted_material.
pub struct TrustedMaterial {
  authorities : Array[Authority]
  timestamp_authorities : Array[Authority]
}

///|
fn authorities(
  value : Json,
  key : String,
) -> Array[Authority] raise VerificationError {
  let values = required_array(value, key)
  guard values.length() <= 100 else {
    raise Invalid("too many trust authorities")
  }
  values.map(authority => {
    let encoded = required_array(
      required(authority, "certChain"),
      "certificates",
    )
    guard encoded.length() >= 1 && encoded.length() <= 10 else {
      raise Invalid("invalid trust certificate chain length")
    }
    let bytes = encoded.map(entry => {
      base64_bytes(required_string(entry, "rawBytes"))
    })
    let period = required(authority, "validFor")
    let (start, start_nanosecond) = timestamp_parts(
      required_string(period, "start"),
    )
    let (end, end_nanosecond) = match optional(period, "end") {
      None => (None, 0)
      Some(String(text)) => {
        let (second, nano) = timestamp_parts(text)
        (Some(second), nano)
      }
      _ => raise Invalid("invalid trust authority end time")
    }
    guard end is None ||
      end.unwrap() > start ||
      (end == Some(start) && end_nanosecond >= start_nanosecond) else {
      raise Invalid("invalid trust authority period")
    }
    Authority::{
      uri: required_string(authority, "uri"),
      certificates: bytes.map(certificate),
      certificate_bytes: bytes,
      start,
      start_nanosecond,
      end,
      end_nanosecond,
    }
  })
}

///|
pub fn TrustedMaterial::from_custom_root(
  bytes : Bytes,
) -> TrustedMaterial raise VerificationError {
  let value = decode_json(bytes)
  guard required_string(value, "mediaType") ==
    "application/vnd.dev.sigstore.trustedroot+json;version=0.1" else {
    raise Invalid("unsupported Sigstore trusted root")
  }
  {
    authorities: authorities(value, "certificateAuthorities"),
    timestamp_authorities: authorities(value, "timestampAuthorities"),
  }
}

///|
pub fn TufTrust::trusted_material(
  self : TufTrust,
  bytes : Bytes,
) -> TrustedMaterial raise VerificationError {
  ignore(self.verify_target("trusted_root.json", bytes))
  TrustedMaterial::from_custom_root(bytes)
}

///|
fn Authority::valid_at(
  self : Authority,
  time : Int64,
  nanosecond~ : Int32 = 0,
) -> Bool {
  nanosecond >= 0 &&
  nanosecond < 1000000000 &&
  (
    time > self.start ||
    (time == self.start && nanosecond >= self.start_nanosecond)
  ) &&
  (
    self.end is None ||
    time < self.end.unwrap() ||
    (time == self.end.unwrap() && nanosecond <= self.end_nanosecond)
  )
}

///|
fn extension(
  cert : @pkix.Certificate,
  name : String,
) -> @pkix.Extension? raise VerificationError {
  let mut found = None
  for ext in cert.tbs.extensions {
    if ext.oid.to_string() == name {
      guard found is None else {
        raise Invalid("duplicate certificate extension")
      }
      found = Some(ext)
    }
  }
  found
}

///|
fn enforce_end_entity(cert : @pkix.Certificate) -> Unit raise VerificationError {
  if extension(cert, "2.5.29.19") is Some(ext) {
    let constraints = sequence(der(ext.value))
    if constraints.length() > 0 && constraints[0].value is Boolean(true) {
      raise Invalid("signer certificate must be an end entity")
    }
  }
}

///|
fn enforce_eku(
  cert : @pkix.Certificate,
  expected : String,
  tsa : Bool,
) -> Unit raise VerificationError {
  guard extension(cert, "2.5.29.37") is Some(ext) else {
    raise Invalid("missing signing certificate EKU")
  }
  let purposes = sequence(der(ext.value)).map(oid)
  guard purposes.contains(expected) else {
    raise Invalid("incorrect signing certificate EKU")
  }
  if tsa {
    guard ext.critical && purposes.length() == 1 else {
      raise Invalid(
        "timestamp certificate requires only critical timestamp EKU",
      )
    }
  }
}

///|
fn verify_chain(
  leaf : @pkix.Certificate,
  intermediates : Array[@pkix.Certificate],
  root : @pkix.Certificate,
  time : String,
  eku : String,
) -> Unit raise VerificationError {
  enforce_end_entity(leaf)
  enforce_eku(leaf, eku, eku == "1.3.6.1.5.5.7.3.8")
  // The dependency validates the leaf EKU; explicitly enforce EKU chaining.
  for cert in intermediates + [root] {
    if extension(cert, "2.5.29.37") is Some(ext) {
      let purposes = sequence(der(ext.value)).map(oid)
      guard purposes.contains(eku) || purposes.contains("2.5.29.37.0") else {
        raise Invalid("intermediate certificate disallows signing purpose")
      }
    }
  }
  let purpose = @asn1.ObjectIdentifier::from_string(eku) catch {
    _ => raise Invalid("invalid signing purpose")
  }
  @pkix_verify.verify_chain_for_signature_with_anchor_cert(
    leaf,
    intermediates,
    root,
    time,
    opts={ required_eku: Some(purpose), required_policy: None, },
  ) catch {
    _ => raise Invalid("certificate chain verification failed")
  }
}

///|
fn verify_release_identity(
  leaf : @pkix.Certificate,
  expected : String,
) -> Unit raise VerificationError {
  guard extension(leaf, "2.5.29.17") is Some(ext) else {
    raise Invalid("missing release signer identity")
  }
  let names = sequence(der(ext.value))
  let matches = names
    .iter()
    .filter(name => {
      name.tag == @asn1.Tag::context(6) &&
      (match name.value {
        Unknown(bytes) => bytes == @utf8.encode(expected)
        _ => false
      })
    })
    .count()
  guard matches == 1 else { raise Invalid("release signer identity mismatch") }
}
