///|
test "GitHub secret sealing matches libsodium crypto_box_seal layout" {
  let recipient_secret = Bytes::makei(32, fn(i) { i.to_byte() })
  let ephemeral_secret = Bytes::makei(32, fn(i) { (32 + i).to_byte() })
  let recipient_public_for_shared = @lib.x25519_public_key(recipient_secret)
  let shared_for_check = @lib.x25519(
    ephemeral_secret, recipient_public_for_shared,
  )
  let hs_for_check = secret_hsalsa20(shared_for_check, Bytes::make(16, b'\x00'))
  let hs_for_check_hex = StringBuilder()
  let hex_for_check = "0123456789abcdef"
  for byte in hs_for_check {
    hs_for_check_hex.write_char(
      hex_for_check.get_char(byte.to_int() >> 4).unwrap(),
    )
    hs_for_check_hex.write_char(
      hex_for_check.get_char(byte.to_int() & 15).unwrap(),
    )
  }
  assert_eq(
    hs_for_check_hex.to_string(),
    "429b61f5d96e37268dfc5114849d599c9ceabffdb68c1f52cd0499af30f5b377",
  )
  let key = Bytes::makei(32, fn(i) { (32 + i).to_byte() })
  let nonce = @base64.decode("3+TlRdLuymdeJ3q1meRiupdhpo5H1V1U") catch {
    _ => fail("nonce fixture is invalid")
  }
  let hsalsa = secret_hsalsa20(key, secret_bytes_slice(nonce, 0, 16))
  let hsalsa_hex = StringBuilder()
  let hex = "0123456789abcdef"
  for byte in hsalsa {
    hsalsa_hex.write_char(hex.get_char(byte.to_int() >> 4).unwrap())
    hsalsa_hex.write_char(hex.get_char(byte.to_int() & 15).unwrap())
  }
  assert_eq(
    hsalsa_hex.to_string(),
    "7b678105f9c88de01663b9304f1699f44f1cadb3519ac07dbd7f96b91ec83ae3",
  )
  let direct = @lib.salsa20_keystream_block(
    hsalsa,
    secret_bytes_slice(nonce, 16, 8),
    0,
  )
  let direct_hex = StringBuilder()
  for byte in direct {
    direct_hex.write_char(hex.get_char(byte.to_int() >> 4).unwrap())
    direct_hex.write_char(hex.get_char(byte.to_int() & 15).unwrap())
  }
  assert_eq(
    direct_hex.to_string(),
    "9f840fe89c6f6784a98e02ce5bec8dad929524b25a867c5439bea990305dd36f0a1da02b1bf5dd8f52467a9317e2f2b1d2b96ea2507652625f8472f1fda808bf",
  )
  let stream = secret_xsalsa20_stream(key, nonce, 46)
  let stream_hex = StringBuilder()
  for byte in stream {
    stream_hex.write_char(hex.get_char(byte.to_int() >> 4).unwrap())
    stream_hex.write_char(hex.get_char(byte.to_int() & 15).unwrap())
  }
  assert_eq(
    stream_hex.to_string(),
    "9f840fe89c6f6784a98e02ce5bec8dad929524b25a867c5439bea990305dd36f0a1da02b1bf5dd8f52467a9317e2",
  )
  let recipient_public = @lib.x25519_public_key(
    Bytes::makei(32, fn(i) { i.to_byte() }),
  )
  let eph_seed = Bytes::makei(32, fn(i) { (32 + i).to_byte() })
  let shared = match @lib.x25519_or(eph_seed, recipient_public) {
    Ok(value) => value
    Err(_) => fail("x25519 fixture failed")
  }
  let shared_hex = StringBuilder()
  for byte in shared {
    shared_hex.write_char(hex.get_char(byte.to_int() >> 4).unwrap())
    shared_hex.write_char(hex.get_char(byte.to_int() & 15).unwrap())
  }
  assert_eq(
    shared_hex.to_string(),
    "9663aa1da97e848a914a436d04163dfbb89178f107f1b5b77ed3854203382854",
  )
  let eph_public = @lib.x25519_public_key(eph_seed)
  let nonce_check = @lib.blake2b(
    secret_concat(eph_public, recipient_public),
    24,
  )
  let nonce_hex = StringBuilder()
  for byte in nonce_check {
    nonce_hex.write_char(hex.get_char(byte.to_int() >> 4).unwrap())
    nonce_hex.write_char(hex.get_char(byte.to_int() & 15).unwrap())
  }
  assert_eq(
    nonce_hex.to_string(),
    "c4d78b52edf69d5c8e48fa3347b032c143adcc41d69d2440",
  )
  let shared_stream = secret_xsalsa20_stream(shared, nonce_check, 46)
  let shared_stream_hex = StringBuilder()
  for byte in shared_stream {
    shared_stream_hex.write_char(hex.get_char(byte.to_int() >> 4).unwrap())
    shared_stream_hex.write_char(hex.get_char(byte.to_int() & 15).unwrap())
  }
  assert_eq(
    shared_stream_hex.to_string(),
    "5b2351e919b2bb97e4c7ec4ec0f762c9dfc6b1e6f06c1cfeb7947d12517f69c5a4a11b28a1de2b4b723b24ecce99",
  )
  let precomputed_for_check = secret_hsalsa20(shared, Bytes::make(16, b'\x00'))
  let pre_stream = secret_xsalsa20_stream(
    precomputed_for_check, nonce_check, 46,
  )
  let pre_stream_hex = StringBuilder()
  for byte in pre_stream {
    pre_stream_hex.write_char(hex.get_char(byte.to_int() >> 4).unwrap())
    pre_stream_hex.write_char(hex.get_char(byte.to_int() & 15).unwrap())
  }
  assert_eq(
    pre_stream_hex.to_string(),
    "8b1bd3784f2e96cff5751e8261543736e8fc8fa335fc59478ec68fa0a0bba143855fd09ed0da2c6ed54ac970c201",
  )
  let sealed_result = github_secret_seal_with_seed(
    recipient_public, b"fixture-secret", eph_seed,
  )
  let sealed_box = match sealed_result {
    Ok(value) => value
    Err(_) => fail("secret sealing failed")
  }
  let encoded = @base64.encode(sealed_box)
  assert_eq(
    encoded, "NYBy1jZYgNGu6jKa35EhODhR7SGijjt16WXQ0s0WYlS5QyXE4g7pi1DaZ1PVAHDO4zao6qWoSUOmL6oCp3U=",
  )
}

///|
test "GitHub secret sealing rejects low-order recipient keys" {
  let result = github_secret_seal_with_seed(
    Bytes::make(32, b'\x00'),
    b"fixture-secret",
    Bytes::makei(32, fn(i) { (32 + i).to_byte() }),
  )
  match result {
    Err(message) =>
      assert_eq(message, "secret public key is not a valid Curve25519 key")
    Ok(_) => fail("low-order recipient key was accepted")
  }
}
