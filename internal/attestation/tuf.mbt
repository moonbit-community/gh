///|
/// A caller supplies the embedded, reviewed bootstrap root. Received roots
/// never become trusted merely because HTTPS delivered them. No mutation is
/// committed until the corresponding role's signatures and metadata pass.
pub struct TufTrust {
  priv mut root : Json
  priv now : Int64
  priv mut timestamp_metadata : Json?
  priv mut snapshot_metadata : Json?
  priv mut targets_metadata : Json?
  priv mut timestamp_ready : Bool
  priv mut snapshot_ready : Bool
  priv mut targets_ready : Bool
}

///|
pub fn TufTrust::new(
  bootstrap : Bytes,
  now_unix~ : Int64,
) -> TufTrust raise VerificationError {
  let envelope = decode_json(bootstrap)
  let root = required(envelope, "signed")
  guard required_string(root, "_type") == "root" &&
    required_integer(root, "version") > 0L else {
    raise Invalid("invalid bootstrap root type or version")
  }
  verify_role(envelope, root, "root")
  {
    root,
    now: now_unix,
    timestamp_metadata: None,
    snapshot_metadata: None,
    targets_metadata: None,
    timestamp_ready: false,
    snapshot_ready: false,
    targets_ready: false,
  }
}

///|
pub fn TufTrust::root_version(self : TufTrust) -> Int64 raise VerificationError {
  required_integer(self.root, "version")
}

///|
/// Cached metadata establishes rollback floors only. It must still verify
/// under the cached root and its referenced hashes, but may now be expired.
/// Restoring it never authorizes a target: fresh online metadata is required.
pub fn TufTrust::restore_previous(
  self : TufTrust,
  timestamp_bytes : Bytes,
  snapshot_bytes : Bytes,
  targets_bytes : Bytes,
) -> Unit raise VerificationError {
  guard self.timestamp_metadata is None else {
    raise Invalid("TUF previous state already loaded")
  }
  let previous : TufTrust = {
    root: self.root,
    now: -9223372036854775807L,
    timestamp_metadata: None,
    snapshot_metadata: None,
    targets_metadata: None,
    timestamp_ready: false,
    snapshot_ready: false,
    targets_ready: false,
  }
  ignore(previous.verify_timestamp(timestamp_bytes))
  ignore(previous.verify_snapshot(snapshot_bytes))
  previous.verify_targets(targets_bytes)
  self.timestamp_metadata = previous.timestamp_metadata
  self.snapshot_metadata = previous.snapshot_metadata
  self.targets_metadata = previous.targets_metadata
}

///|
pub fn TufTrust::metadata_filename(
  self : TufTrust,
  name : String,
  version : Int64,
) -> String raise VerificationError {
  guard (name == "snapshot.json" || name == "targets.json") && version > 0 else {
    raise Invalid("invalid TUF metadata filename")
  }
  if required(self.root, "consistent_snapshot") is True {
    version.to_string() + "." + name
  } else {
    name
  }
}

///|
pub fn TufTrust::rotate_root(
  self : TufTrust,
  bytes : Bytes,
) -> Unit raise VerificationError {
  let envelope = decode_json(bytes)
  let next = required(envelope, "signed")
  guard required_string(next, "_type") == "root" &&
    required_integer(next, "version") == self.root_version() + 1L else {
    raise Invalid("TUF root version must advance exactly once")
  }
  verify_role(envelope, self.root, "root")
  verify_role(envelope, next, "root")
  // TUF 1.0 section 5.3.11: an authenticated rotation of either online
  // role's keys resets timestamp/snapshot rollback floors, permitting recovery
  // from a compromised online key's fast-forward attack. Targets comparison
  // state derives from that snapshot and must be refreshed as well.
  // https://theupdateframework.github.io/specification/latest/#load-root-metadata
  if !same_role_keys(self.root, next, "timestamp") ||
    !same_role_keys(self.root, next, "snapshot") {
    self.timestamp_metadata = None
    self.snapshot_metadata = None
    self.targets_metadata = None
  }
  self.root = next
  self.timestamp_ready = false
  self.snapshot_ready = false
  self.targets_ready = false
}

///|
fn same_role_keys(
  before : Json,
  after : Json,
  role : String,
) -> Bool raise VerificationError {
  let old_ids = required_array(
    required(required(before, "roles"), role),
    "keyids",
  )
  let new_ids = required_array(
    required(required(after, "roles"), role),
    "keyids",
  )
  if old_ids.length() != new_ids.length() {
    return false
  }
  let old_keys = required(before, "keys")
  let new_keys = required(after, "keys")
  for id in old_ids {
    guard id is String(id) else { raise Invalid("invalid TUF role key ID") }
    if !new_ids.contains(Json(id)) ||
      required(old_keys, id) != required(new_keys, id) {
      return false
    }
  }
  true
}

///|
fn require_fresh(metadata : Json, now : Int64) -> Unit raise VerificationError {
  guard timestamp(required_string(metadata, "expires")) > now else {
    raise Invalid("expired TUF metadata")
  }
}

///|
fn verify_role(
  envelope : Json,
  root : Json,
  role : String,
) -> Unit raise VerificationError {
  let definition = required(required(root, "roles"), role)
  let threshold = required_integer(definition, "threshold")
  guard required(definition, "keyids") is Array(key_ids) &&
    required(envelope, "signatures") is Array(signatures) &&
    threshold > 0 &&
    threshold <= key_ids.length().to_int64() &&
    key_ids.length() <= 256 &&
    signatures.length() <= 256 else {
    raise Invalid("invalid TUF role threshold")
  }
  let payload = @utf8.encode(canonical_json(required(envelope, "signed")))
  let keys = required(root, "keys")
  let verified : Map[String, Unit] = Map([])
  for signature in signatures {
    let key_id = required_string(signature, "keyid")
    if verified.contains(key_id) || !key_ids.contains(Json(key_id)) {
      continue
    }
    let key = required(keys, key_id)
    let valid = try {
      let public = required_string(required(key, "keyval"), "public")
      let encoded = required_string(signature, "sig")
      guard encoded.length() <= 512 else {
        raise Invalid("oversized TUF signature")
      }
      let signature = decode_hex(encoded)
      match (required_string(key, "keytype"), required_string(key, "scheme")) {
        ("ecdsa", "ecdsa-sha2-nistp256") => {
          let block = @pem.decode_strict(public)
          guard block.label == "PUBLIC KEY" else {
            raise Invalid("invalid TUF public key")
          }
          @p256.verify(
            @p256.PublicKey::from_spki_der(block.data),
            payload,
            signature,
            Der,
          )
        }
        ("ed25519", "ed25519") =>
          @ed25519.PublicKey::from_bytes(decode_hex(public)).verify_strict(
            payload, signature,
          )
        _ => false
      }
    } catch {
      _ => false
    }
    if valid {
      verified[key_id] = ()
    }
  }
  guard verified.length().to_int64() >= threshold else {
    raise Invalid("TUF signature threshold not met")
  }
}

///|
fn metadata_reference(
  metadata : Json,
  name : String,
) -> Json raise VerificationError {
  required(required(metadata, "meta"), name)
}

///|
fn verify_size_hash(
  bytes : Bytes,
  descriptor : Json,
  require_hash~ : Bool,
) -> Unit raise VerificationError {
  guard descriptor is Object(fields) else {
    raise Invalid("invalid TUF file descriptor")
  }
  if require_hash {
    ignore(required_integer(descriptor, "length"))
  }
  if fields.contains("length") &&
    required_integer(descriptor, "length") != bytes.length().to_int64() {
    raise Invalid("TUF file length mismatch")
  }
  let mut verified = 0
  if fields.get("hashes") is Some(Object(hashes)) {
    for name, value in hashes {
      guard value is String(digest) else { raise Invalid("invalid TUF hash") }
      let expected = decode_hex(digest)
      let actual = match name {
        "sha256" => @hash.sha256(bytes)
        "sha512" => @hash.sha512(bytes)
        _ => continue
      }
      guard @hash.ct_eq(actual, expected) else {
        raise Invalid("TUF file hash mismatch")
      }
      verified += 1
    }
  }
  guard !require_hash || verified > 0 else {
    raise Invalid("missing supported TUF target hash")
  }
}

///|
pub fn TufTrust::verify_timestamp(
  self : TufTrust,
  bytes : Bytes,
) -> Int64 raise VerificationError {
  require_fresh(self.root, self.now)
  let envelope = decode_json(bytes)
  let metadata = required(envelope, "signed")
  guard required_string(metadata, "_type") == "timestamp" &&
    required_integer(metadata, "version") > 0L else {
    raise Invalid("invalid timestamp type or version")
  }
  verify_role(envelope, self.root, "timestamp")
  require_fresh(metadata, self.now)
  let snapshot_version = required_integer(
    metadata_reference(metadata, "snapshot.json"),
    "version",
  )
  guard snapshot_version > 0L else {
    raise Invalid("invalid snapshot reference version")
  }
  if self.timestamp_metadata is Some(previous) {
    guard required_integer(metadata, "version") >=
      required_integer(previous, "version") &&
      snapshot_version >=
      required_integer(metadata_reference(previous, "snapshot.json"), "version") else {
      raise Invalid("TUF timestamp rollback")
    }
    if required_integer(metadata, "version") ==
      required_integer(previous, "version") &&
      metadata != previous {
      raise Invalid("TUF timestamp changed without a version increment")
    }
  }
  self.timestamp_metadata = Some(metadata)
  self.timestamp_ready = true
  self.snapshot_ready = false
  self.targets_ready = false
  snapshot_version
}

///|
pub fn TufTrust::verify_snapshot(
  self : TufTrust,
  bytes : Bytes,
) -> Int64 raise VerificationError {
  guard self.timestamp_ready &&
    self.timestamp_metadata is Some(timestamp_metadata) else {
    raise Invalid("timestamp must be verified first")
  }
  let descriptor = metadata_reference(timestamp_metadata, "snapshot.json")
  verify_size_hash(bytes, descriptor, require_hash=false)
  let envelope = decode_json(bytes)
  let metadata = required(envelope, "signed")
  guard required_string(metadata, "_type") == "snapshot" &&
    required_integer(metadata, "version") ==
    required_integer(descriptor, "version") else {
    raise Invalid("TUF snapshot version mismatch")
  }
  verify_role(envelope, self.root, "snapshot")
  require_fresh(metadata, self.now)
  if self.snapshot_metadata is Some(previous) {
    guard required_integer(metadata, "version") >=
      required_integer(previous, "version") else {
      raise Invalid("TUF snapshot rollback")
    }
    if required_integer(metadata, "version") ==
      required_integer(previous, "version") &&
      metadata != previous {
      raise Invalid("TUF snapshot changed without a version increment")
    }
    guard required(previous, "meta") is Object(old) else {
      raise Invalid("invalid previous snapshot")
    }
    for name, descriptor in old {
      guard required_integer(metadata_reference(metadata, name), "version") >=
        required_integer(descriptor, "version") else {
        raise Invalid("TUF delegated metadata rollback")
      }
    }
  }
  let version = required_integer(
    metadata_reference(metadata, "targets.json"),
    "version",
  )
  guard version > 0L else { raise Invalid("invalid targets reference version") }
  self.snapshot_metadata = Some(metadata)
  self.snapshot_ready = true
  self.targets_ready = false
  version
}

///|
pub fn TufTrust::verify_targets(
  self : TufTrust,
  bytes : Bytes,
) -> Unit raise VerificationError {
  guard self.snapshot_ready && self.snapshot_metadata is Some(snapshot) else {
    raise Invalid("snapshot must be verified first")
  }
  let descriptor = metadata_reference(snapshot, "targets.json")
  verify_size_hash(bytes, descriptor, require_hash=false)
  let envelope = decode_json(bytes)
  let metadata = required(envelope, "signed")
  guard required_string(metadata, "_type") == "targets" &&
    required_integer(metadata, "version") ==
    required_integer(descriptor, "version") else {
    raise Invalid("TUF targets version mismatch")
  }
  verify_role(envelope, self.root, "targets")
  require_fresh(metadata, self.now)
  if self.targets_metadata is Some(previous) &&
    required_integer(metadata, "version") <
    required_integer(previous, "version") {
    raise Invalid("TUF targets rollback")
  }
  if self.targets_metadata is Some(previous) &&
    required_integer(metadata, "version") ==
    required_integer(previous, "version") &&
    metadata != previous {
    raise Invalid("TUF targets changed without a version increment")
  }
  self.targets_metadata = Some(metadata)
  self.targets_ready = true
}

///|
pub fn TufTrust::target_filename(
  self : TufTrust,
  name : String,
) -> String raise VerificationError {
  guard self.targets_ready &&
    self.targets_metadata is Some(targets) &&
    (name == "trusted_root.json" || name == "dotcom.trusted_root.json") else {
    raise Invalid("unregistered GitHub trust target")
  }
  let descriptor = required(required(targets, "targets"), name)
  if required(self.root, "consistent_snapshot") is True {
    let digest = required_string(required(descriptor, "hashes"), "sha256")
    guard decode_hex(digest).length() == 32 else {
      raise Invalid("invalid TUF target digest")
    }
    digest + "." + name
  } else {
    name
  }
}

///|
pub fn TufTrust::verify_target(
  self : TufTrust,
  name : String,
  bytes : Bytes,
) -> Json raise VerificationError {
  ignore(self.target_filename(name))
  let descriptor = required(
    required(self.targets_metadata.unwrap(), "targets"),
    name,
  )
  verify_size_hash(bytes, descriptor, require_hash=true)
  decode_json(bytes)
}
