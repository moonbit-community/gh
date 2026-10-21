/// GitHub Actions secret encryption uses libsodium's `crypto_box_seal`
/// construction.  The API publishes a base64-encoded Curve25519 public key;
/// values are sealed locally and sent as `encrypted_value` together with the
/// key id returned by the public-key endpoint.  Keep this code in the native
/// facade because the runtime owns the CSPRNG and HTTP request sequence.

///|
fn secret_bytes_slice(value : Bytes, start : Int32, length : Int32) -> Bytes {
  Bytes::makei(length, fn(i) { value[start + i] })
}

///|
fn secret_concat(a : Bytes, b : Bytes) -> Bytes {
  Bytes::makei(a.length() + b.length(), fn(i) {
    if i < a.length() {
      a[i]
    } else {
      b[i - a.length()]
    }
  })
}

///|
fn secret_le_u32(bytes : Bytes, offset : Int32) -> UInt32 {
  bytes[offset].to_uint() |
  (bytes[offset + 1].to_uint() << 8) |
  (bytes[offset + 2].to_uint() << 16) |
  (bytes[offset + 3].to_uint() << 24)
}

///|
fn secret_write_le_u32(
  out : Array[Byte],
  offset : Int32,
  value : UInt32,
) -> Unit {
  out[offset] = (value & 0xFFU).to_byte()
  out[offset + 1] = ((value >> 8) & 0xFFU).to_byte()
  out[offset + 2] = ((value >> 16) & 0xFFU).to_byte()
  out[offset + 3] = ((value >> 24) & 0xFFU).to_byte()
}

///|
fn secret_rotl(value : UInt32, bits : Int32) -> UInt32 {
  (value << bits) | (value >> (32 - bits))
}

///|
fn secret_hsalsa20(key : Bytes, nonce16 : Bytes) -> Bytes {
  // HSalsa20 uses the standard Salsa20 constants and omits the final feed
  // forward.  The output word order is specified by the XSalsa20 construction.
  let x = Array::make(16, 0U)
  x[0] = 0x61707865U
  x[5] = 0x3320646eU
  x[10] = 0x79622d32U
  x[15] = 0x6b206574U
  x[1] = secret_le_u32(key, 0)
  x[2] = secret_le_u32(key, 4)
  x[3] = secret_le_u32(key, 8)
  x[4] = secret_le_u32(key, 12)
  x[11] = secret_le_u32(key, 16)
  x[12] = secret_le_u32(key, 20)
  x[13] = secret_le_u32(key, 24)
  x[14] = secret_le_u32(key, 28)
  x[6] = secret_le_u32(nonce16, 0)
  x[7] = secret_le_u32(nonce16, 4)
  x[8] = secret_le_u32(nonce16, 8)
  x[9] = secret_le_u32(nonce16, 12)
  for _ in 0..<10 {
    // Column round.
    x[4] = x[4] ^ secret_rotl(x[0] + x[12], 7)
    x[8] = x[8] ^ secret_rotl(x[4] + x[0], 9)
    x[12] = x[12] ^ secret_rotl(x[8] + x[4], 13)
    x[0] = x[0] ^ secret_rotl(x[12] + x[8], 18)
    x[9] = x[9] ^ secret_rotl(x[5] + x[1], 7)
    x[13] = x[13] ^ secret_rotl(x[9] + x[5], 9)
    x[1] = x[1] ^ secret_rotl(x[13] + x[9], 13)
    x[5] = x[5] ^ secret_rotl(x[1] + x[13], 18)
    x[14] = x[14] ^ secret_rotl(x[10] + x[6], 7)
    x[2] = x[2] ^ secret_rotl(x[14] + x[10], 9)
    x[6] = x[6] ^ secret_rotl(x[2] + x[14], 13)
    x[10] = x[10] ^ secret_rotl(x[6] + x[2], 18)
    x[3] = x[3] ^ secret_rotl(x[15] + x[11], 7)
    x[7] = x[7] ^ secret_rotl(x[3] + x[15], 9)
    x[11] = x[11] ^ secret_rotl(x[7] + x[3], 13)
    x[15] = x[15] ^ secret_rotl(x[11] + x[7], 18)
    // Row round.
    x[1] = x[1] ^ secret_rotl(x[0] + x[3], 7)
    x[2] = x[2] ^ secret_rotl(x[1] + x[0], 9)
    x[3] = x[3] ^ secret_rotl(x[2] + x[1], 13)
    x[0] = x[0] ^ secret_rotl(x[3] + x[2], 18)
    x[6] = x[6] ^ secret_rotl(x[5] + x[4], 7)
    x[7] = x[7] ^ secret_rotl(x[6] + x[5], 9)
    x[4] = x[4] ^ secret_rotl(x[7] + x[6], 13)
    x[5] = x[5] ^ secret_rotl(x[4] + x[7], 18)
    x[11] = x[11] ^ secret_rotl(x[10] + x[9], 7)
    x[8] = x[8] ^ secret_rotl(x[11] + x[10], 9)
    x[9] = x[9] ^ secret_rotl(x[8] + x[11], 13)
    x[10] = x[10] ^ secret_rotl(x[9] + x[8], 18)
    x[12] = x[12] ^ secret_rotl(x[15] + x[14], 7)
    x[13] = x[13] ^ secret_rotl(x[12] + x[15], 9)
    x[14] = x[14] ^ secret_rotl(x[13] + x[12], 13)
    x[15] = x[15] ^ secret_rotl(x[14] + x[13], 18)
  }
  let out = Array::make(32, b'\x00')
  for
    (i, word) in [
      (0, x[0]),
      (4, x[5]),
      (8, x[10]),
      (12, x[15]),
      (16, x[6]),
      (20, x[7]),
      (24, x[8]),
      (28, x[9]),
    ] {
    secret_write_le_u32(out, i, word)
  }
  Bytes::from_array(out[:])
}

///|
fn secret_xsalsa20_stream(key : Bytes, nonce : Bytes, length : Int32) -> Bytes {
  let subkey = secret_hsalsa20(key, secret_bytes_slice(nonce, 0, 16))
  let nonce8 = secret_bytes_slice(nonce, 16, 8)
  let out = Array::make(length, b'\x00')
  let mut block = 0
  let mut offset = 0
  while offset < length {
    let stream = @lib.salsa20_keystream_block(subkey, nonce8, block)
    let take = if length - offset < 64 { length - offset } else { 64 }
    for i in 0..<take {
      out[offset + i] = stream[i]
    }
    offset += take
    block += 1
  }
  Bytes::from_array(out[:])
}

///|
fn secret_box_seal(box_key : Bytes, nonce : Bytes, message : Bytes) -> Bytes {
  // The caller supplies crypto_box_beforenm's HSalsa20 precomputed key;
  // crypto_secretbox_easy then applies XSalsa20-Poly1305 with the full nonce.
  let stream = secret_xsalsa20_stream(box_key, nonce, message.length() + 32)
  let poly_key = secret_bytes_slice(stream, 0, 32)
  let ciphertext = Bytes::makei(message.length(), fn(i) {
    (message[i].to_int() ^ stream[i + 32].to_int()).to_byte()
  })
  let tag = @lib.poly1305(poly_key, ciphertext)
  secret_concat(tag, ciphertext)
}

///|
/// Deterministic form used by the fixture tests. `ephemeral_seed` is clamped
/// by X25519 exactly as libsodium does for the random ephemeral secret.
fn github_secret_seal_with_seed(
  public_key : Bytes,
  message : Bytes,
  ephemeral_seed : Bytes,
) -> Result[Bytes, String] {
  guard public_key.length() == 32 else {
    return Err("secret public key must decode to 32 bytes")
  }
  guard ephemeral_seed.length() == 32 else {
    return Err("secret ephemeral key must be 32 bytes")
  }
  let ephemeral_public = @lib.x25519_public_key(ephemeral_seed)
  let shared = match @lib.x25519_or(ephemeral_seed, public_key) {
    Ok(value) => value
    Err(_) => return Err("secret public key is not a valid Curve25519 key")
  }
  // `crypto_box_easy` first applies the Curve25519 precomputation step
  // (HSalsa20 with an all-zero nonce) and then passes that key to the
  // XSalsa20-Poly1305 secretbox primitive.  Keep this two-stage derivation
  // explicit; sealing the raw ECDH output directly produces a different,
  // invalid box for GitHub's crypto_box_seal endpoint.
  // libsodium's crypto_scalarmult rejects low-order points whose shared
  // secret is all zero.  Keep that boundary check before deriving the
  // symmetric key so malformed endpoint data cannot produce a box under a
  // predictable key.
  guard !@lib.dh_shared_is_zero(shared) else {
    return Err("secret public key is not a valid Curve25519 key")
  }
  let precomputed = secret_hsalsa20(shared, Bytes::make(16, b'\x00'))
  // crypto_box_seal_nonce = BLAKE2b-192(ephemeral_public || recipient_public).
  let nonce_input = secret_concat(ephemeral_public, public_key)
  let nonce = @lib.blake2b(nonce_input, 24)
  let boxed = secret_box_seal(precomputed, nonce, message)
  Ok(secret_concat(ephemeral_public, boxed))
}

///|
fn github_secret_encrypt(
  public_key : Bytes,
  message : Bytes,
) -> Result[String, String] {
  guard message.length() <= 49152 else {
    return Err("secret value exceeds GitHub's 48 KiB limit")
  }
  let seed = @getrandom.bytes(32) catch {
    _ => return Err("secure randomness is unavailable")
  }
  match github_secret_seal_with_seed(public_key, message, seed) {
    Ok(value) => Ok(@base64.encode(value))
    Err(error) => Err(error)
  }
}

///|
fn business_secret_key_response(
  response : @github.RawResponse,
) -> Result[(String, Bytes), String] {
  let value : Json = @json.parse(@utf8.decode(response.body())) catch {
    _ => return Err("secret public-key response is invalid JSON")
  }
  match value {
    Object(fields) => {
      let key_id = match fields.get("key_id") {
        Some(String(value)) if !value.is_empty() => value
        _ => return Err("secret public-key response has no key_id")
      }
      let key = match fields.get("key") {
        Some(String(value)) =>
          @base64.decode(value) catch {
            _ => return Err("secret public-key response has an invalid key")
          }
        _ => return Err("secret public-key response has no key")
      }
      Ok((key_id, key))
    }
    _ => Err("secret public-key response is not an object")
  }
}

///|
async fn execute_secret_set(
  parsed : ParsedBusiness,
  request : BusinessRequest,
  client : @github.Client,
  repository? : @github_cli.RepositoryContext,
) -> @github_cli.Output {
  let repo = match business_explicit_repository(parsed.command, parsed) {
    Some(value) =>
      match @github_cli.RepositoryContext::parse(value) {
        Ok(value) => Some(value)
        Err(_) => None
      }
    None => repository
  }
  let key_path = match parsed.values.get("org") {
    Some(org) => {
      guard parsed.values.get("env") is None else {
        return @github_cli.failure(
          message="--org cannot be combined with --env",
        )
      }
      let org = match business_segment(org) {
        Ok(value) => value
        Err(_) => return @github_cli.failure(message="invalid organization")
      }
      "/orgs/" + org + "/actions/secrets/public-key"
    }
    None =>
      match parsed.values.get("env") {
        Some(environment) => {
          guard repo is Some(repo) else {
            return @github_cli.failure(
              message="a repository is required for --env",
            )
          }
          let environment = match business_segment(environment) {
            Ok(value) => value
            Err(_) => return @github_cli.failure(message="invalid environment")
          }
          repo_api_path(repo) +
          "/environments/" +
          environment +
          "/secrets/public-key"
        }
        None =>
          match repo {
            Some(repo) => repo_api_path(repo) + "/actions/secrets/public-key"
            None =>
              return @github_cli.failure(message="a repository is required")
          }
      }
  }
  let value = match parsed.values.get("body") {
    Some(value) => value
    None =>
      match parsed.values.get("value") {
        Some(value) => value
        None => return @github_cli.failure(message="secret value is required")
      }
  }
  let key_request = @github.Request::new(verb="GET", path=key_path)
  let key_response = match
    client.request(
      key_request,
      operation_id="secret-public-key",
      operation_name="secret.public-key",
    ) {
    Ok(response) => response
    Err(error) =>
      match error.response() {
        Some(response) => response
        None => return @github_cli.failure(message=error.code())
      }
  }
  guard key_response.status() >= 200 && key_response.status() < 300 else {
    return render_github_response(
      key_response.status(),
      key_response.headers(),
      key_response.body(),
      jq?=request.jq,
      template?=request.template,
      include_headers=request.include_headers,
      silent=request.silent,
      verbose=request.verbose,
    )
  }
  let (key_id, public_key) = match business_secret_key_response(key_response) {
    Ok(value) => value
    Err(message) => return @github_cli.failure(message~)
  }
  let encrypted = match github_secret_encrypt(public_key, @utf8.encode(value)) {
    Ok(value) => value
    Err(message) => return @github_cli.failure(message~)
  }
  let body : Map[String, Json] = Map([])
  body["encrypted_value"] = Json::string(encrypted)
  body["key_id"] = Json::string(key_id)
  let put_request = @github.Request::new(
    verb="PUT",
    path=request.path,
    headers=request.headers,
    body=@utf8.encode(Json::object(body).stringify()),
  )
  let response = match
    client.request(
      put_request,
      operation_id="secret-set",
      operation_name="secret.set",
    ) {
    Ok(response) => response
    Err(error) =>
      match error.response() {
        Some(response) => response
        None => return @github_cli.failure(message=error.code())
      }
  }
  render_github_response(
    response.status(),
    response.headers(),
    response.body(),
    jq?=request.jq,
    template?=request.template,
    include_headers=request.include_headers,
    silent=request.silent,
    verbose=request.verbose,
  )
}
