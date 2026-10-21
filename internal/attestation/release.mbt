///|
pub struct VerifiedRelease {
  statement : Json
  signed_at : Int64
  timestamp_uri : String
  timestamp_text : String
  issuer : String
}

///|
pub fn VerifiedRelease::statement(self : VerifiedRelease) -> Json {
  self.statement
}

///|
pub fn VerifiedRelease::signed_at(self : VerifiedRelease) -> Int64 {
  self.signed_at
}

///|
fn verify_envelope_signature(
  leaf : @pkix.Certificate,
  message : Bytes,
  signature : Bytes,
) -> Unit raise VerificationError {
  let key = @pkix_verify.extract_public_key(leaf.tbs.subject_public_key_info) catch {
    _ => raise Invalid("unsupported release signing key")
  }
  let signature_oid = match key {
    P256(_) => "1.2.840.10045.4.3.2"
    P384(_) => "1.2.840.10045.4.3.3"
    Rsa(_) => "1.2.840.113549.1.1.11"
    Ed25519(_) => "1.3.101.112"
  }
  let algorithm = @asn1.ObjectIdentifier::from_string(signature_oid) catch {
    _ => raise Invalid("invalid envelope signature algorithm")
  }
  @pkix_verify.verify_signature(
    message,
    { algorithm, parameters: None, },
    { bytes: signature, unused_bits: 0, },
    key,
  ) catch {
    _ => raise Invalid("release envelope signature verification failed")
  }
}

///|
/// This is the GitHub Release policy, not the general attestation command.
/// The authenticated statement must bind the requested tag and ref digest;
/// optional asset verification additionally binds the local file SHA-256.
pub fn TrustedMaterial::verify_release(
  self : TrustedMaterial,
  bundle_bytes : Bytes,
  tag~ : String,
  ref_digest~ : String,
  asset_sha256? : String,
  now_unix~ : Int64,
) -> VerifiedRelease raise VerificationError {
  let bundle = decode_json(bundle_bytes)
  guard required_string(bundle, "mediaType") ==
    "application/vnd.dev.sigstore.bundle.v0.3+json" else {
    raise Invalid("unsupported release bundle version")
  }
  let material = required(bundle, "verificationMaterial")
  let leaf = certificate(
    base64_bytes(required_string(required(material, "certificate"), "rawBytes")),
  )
  verify_release_identity(leaf, "https://dotcom.releases.github.com")
  let envelope = required(bundle, "dsseEnvelope")
  let payload_type = required_string(envelope, "payloadType")
  guard payload_type == "application/vnd.in-toto+json" else {
    raise Invalid("unsupported release envelope payload type")
  }
  let payload = base64_bytes(required_string(envelope, "payload"))
  let signatures = required_array(envelope, "signatures")
  guard signatures.length() == 1 else {
    raise Invalid("release envelope must have one signature")
  }
  let signature = base64_bytes(required_string(signatures[0], "sig"))
  let pae = @utf8.encode(
      "DSSEv1 \{@utf8.encode(payload_type).length()} \{payload_type} \{payload.length()} ",
    ) +
    payload
  verify_envelope_signature(leaf, pae, signature)
  let timestamps = required_array(
    required(material, "timestampVerificationData"),
    "rfc3161Timestamps",
  )
  guard !timestamps.is_empty() && timestamps.length() <= 32 else {
    raise Invalid("release requires a bounded signed timestamp set")
  }
  let mut signed_at = None
  let mut timestamp_uri = ""
  let mut timestamp_text = ""
  for timestamp_value in timestamps {
    let verified_time = try {
      let token = timestamp_token(
        base64_bytes(required_string(timestamp_value, "signedTimestamp")),
        signature,
      )
      guard token.upper_unix_time <= now_unix else {
        raise Invalid("release timestamp is in the future")
      }
      let mut trusted_timestamp = false
      for authority in self.timestamp_authorities {
        let valid = try {
          verify_timestamp_authority(token, authority)
          true
        } catch {
          _ => false
        }
        if valid {
          trusted_timestamp = true
          timestamp_uri = authority.uri
          break
        }
      }
      guard trusted_timestamp else {
        raise Invalid("no trusted timestamp authority verified the timestamp")
      }
      let mut trusted_signer = false
      for authority in self.authorities {
        if !authority.valid_at(token.unix_time, nanosecond=token.nanosecond) {
          continue
        }
        let certificates = authority.certificates
        // GitHub release certificates may be issued directly by l1, whereas
        // the same trusted authority also carries l2 for other identities.
        // Build only the actual issuer path, retaining the pinned root.
        for start in 0..<certificates.length() {
          if @pkix.serialize_name(certificates[start].tbs.subject) !=
            @pkix.serialize_name(leaf.tbs.issuer) {
            continue
          }
          let valid = try {
            verify_chain(
              leaf,
              certificates[start:certificates.length() - 1].to_owned(),
              certificates[certificates.length() - 1],
              token.certificate_time,
              "1.3.6.1.5.5.7.3.3",
            )
            if token.certificate_upper_time != token.certificate_time {
              verify_chain(
                leaf,
                certificates[start:certificates.length() - 1].to_owned(),
                certificates[certificates.length() - 1],
                token.certificate_upper_time,
                "1.3.6.1.5.5.7.3.3",
              )
            }
            true
          } catch {
            _ => false
          }
          if valid {
            trusted_signer = true
            break
          }
        }
        if trusted_signer {
          break
        }
      }
      guard trusted_signer else {
        raise Invalid("release signer was not trusted at the signed timestamp")
      }
      timestamp_text = token.text_time
      Some(token.unix_time)
    } catch {
      _ => None
    }
    if verified_time is Some(time) {
      signed_at = Some(time)
      break
    }
  }
  guard signed_at is Some(signed_at) else {
    raise Invalid(
      "release signed timestamp and certificate verification failed",
    )
  }
  let statement = decode_json(payload)
  guard required_string(statement, "_type") == "https://in-toto.io/Statement/v1" &&
    required_string(statement, "predicateType")
    is ("https://in-toto.io/attestation/release/v0.1"
    | "https://in-toto.io/attestation/release/v0.2") else {
    raise Invalid("not a release attestation statement")
  }
  guard required_string(required(statement, "predicate"), "tag") == tag else {
    raise Invalid("attested release tag mismatch")
  }
  let parts = ref_digest.split(":").map(part => part.to_owned()).collect()
  guard parts.length() == 2 &&
    (
      (parts[0] == "sha1" && parts[1].length() == 40) ||
      (parts[0] == "sha256" && parts[1].length() == 64)
    ) else {
    raise Invalid("invalid release ref digest")
  }
  let ref_bytes = decode_hex(parts[1])
  let subjects = required_array(statement, "subject")
  guard !subjects.is_empty() && subjects.length() <= 10000 else {
    raise Invalid("invalid release subjects")
  }
  let mut ref_present = false
  let mut asset_present = asset_sha256 is None
  let expected_asset = match asset_sha256 {
    Some(value) => Some(decode_hex(value))
    None => None
  }
  if expected_asset is Some(value) {
    guard value.length() == 32 else {
      raise Invalid("invalid release asset digest")
    }
  }
  for subject in subjects {
    let hashes = required(subject, "digest")
    if optional(hashes, parts[0]) is Some(String(value)) &&
      @hash.ct_eq(decode_hex(value), ref_bytes) {
      ref_present = true
    }
    if expected_asset is Some(expected) &&
      optional(hashes, "sha256") is Some(String(value)) &&
      @hash.ct_eq(decode_hex(value), expected) {
      asset_present = true
    }
  }
  guard ref_present else {
    raise Invalid("release ref digest is not in the attested subjects")
  }
  guard asset_present else {
    raise Invalid("asset digest is not in the attested subjects")
  }
  {
    statement,
    signed_at,
    timestamp_uri,
    timestamp_text,
    issuer: distinguished_name(leaf.tbs.issuer),
  }
}
