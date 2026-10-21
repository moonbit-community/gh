///|
fn public_trust_fixture(url : String) -> @gh.RawHttpResponse raise {
  guard url.strip_prefix("https://tuf-repo.github.com/") is Some(path) else {
    fail("unexpected public trust URL")
  }
  if path == "10.root.json" {
    return @gh.RawHttpResponse::new(status=404)
  }
  let name = path.to_owned().replace_all(old="/", new="__")
  @gh.RawHttpResponse::new(status=200, body=native_trust_fixture(name))
}

///|
async test "TUF cache revalidates signatures restores rollback floors and commits atomically" {
  let directory = @fs.tmpdir(prefix="gh-trust-cache-")
  defer @fs.rmdir(directory, recursive=true)
  let seen : Array[String] = []
  async fn fetch(url : String) -> @gh.RawHttpResponse {
    @async.sleep(1)
    seen.push(url)
    public_trust_fixture(url)
  }
  let roots = load_release_trust(None, Some(directory), fetch, 1792540800L)
  assert_eq(roots.length(), 1)
  assert_eq(seen.length(), 11)
  let state_path = directory + "/github-release-trust/state.json"
  let original = @fs.read_file(state_path).binary()
  seen.clear()
  ignore(load_release_trust(None, Some(directory), fetch, 1792540800L))
  assert_eq(seen.length(), 5)
  assert_eq(seen[0], "https://tuf-repo.github.com/10.root.json")
  assert_eq(@fs.read_file(state_path).binary(), original)
  // A verified old cache establishes version floors, not permission to use
  // expired online timestamp metadata.
  assert_true(
    try {
      ignore(load_release_trust(None, Some(directory), fetch, 1793232000L))
      false
    } catch {
      @attestation.Invalid(message) => message == "expired TUF metadata"
      _ => false
    },
  )
  assert_eq(@fs.read_file(state_path).binary(), original)
  // Signature corruption in the local state is detected before any request.
  let cached = @json.parse(@utf8.decode(original))
  guard cached is Object(fields) &&
    fields.get("timestamp") is Some(String(encoded)) else {
    fail("cache fixture")
  }
  fields["timestamp"] = Json(
    @base64.encode(
      @utf8.encode(
        @utf8.decode(@base64.decode(encoded)).replace_all(old="994", new="995"),
      ),
    ),
  )
  @fs.write_file(state_path, cached.stringify())
  seen.clear()
  assert_true(
    try {
      ignore(load_release_trust(None, Some(directory), fetch, 1792540800L))
      false
    } catch {
      _ => true
    },
  )
  assert_true(seen.is_empty())
}

///|
async test "public proof URLs reject unrelated hosts userinfo and insecure redirects before sending" {
  for
    url in [
      "http://tuf-repo.github.com/timestamp.json", "https://tuf-repo.github.com.attacker.invalid/timestamp.json",
      "https://tuf-repo.github.com@attacker.invalid/timestamp.json", "https://example.invalid/bundle",
      "https://x.blob.core.windows.net@attacker.invalid/bundle", "https://x.blob.core.windows.net/bundle#fragment",
    ] {
    assert_true(
      try {
        ignore(attestation_public_fetch(url))
        false
      } catch {
        _ => true
      },
    )
  }
}

///|
async test "verified TUF roots survive later metadata failure and are replayed before reconnecting" {
  let directory = @fs.tmpdir(prefix="gh-trust-root-floor-")
  defer @fs.rmdir(directory, recursive=true)
  let seen : Array[String] = []
  async fn failed_fetch(url : String) -> @gh.RawHttpResponse {
    @async.sleep(1)
    seen.push(url)
    if url == "https://tuf-repo.github.com/timestamp.json" {
      @gh.RawHttpResponse::new(status=503)
    } else {
      public_trust_fixture(url)
    }
  }
  assert_true(
    try {
      ignore(
        load_release_trust(None, Some(directory), failed_fetch, 1792540800L),
      )
      false
    } catch {
      _ => true
    },
  )
  assert_false(@fs.exists(directory + "/github-release-trust/state.json"))
  let path = directory + "/github-release-trust/roots.json"
  guard @json.parse(@fs.read_file(path).text()) is { "roots": Array(roots), .. } else {
    fail("root cache missing")
  }
  assert_eq(roots.length(), 6)
  seen.clear()
  async fn recovered_fetch(url : String) -> @gh.RawHttpResponse {
    @async.sleep(1)
    seen.push(url)
    public_trust_fixture(url)
  }
  ignore(
    load_release_trust(None, Some(directory), recovered_fetch, 1792540800L),
  )
  assert_eq(seen.length(), 5)
  assert_eq(seen[0], "https://tuf-repo.github.com/10.root.json")
}
