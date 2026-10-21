///|
/// External proof data never uses the authenticated GitHub client. Both the
/// first URL and any redirect must pass this allowlist before network I/O.
async fn attestation_public_fetch(url : String) -> @gh.RawHttpResponse {
  let visited : Map[String, Unit] = Map([])
  let mut current = url
  for _ in 0..<6 {
    guard !visited.contains(current) else { fail("attestation redirect cycle") }
    visited[current] = ()
    guard current.strip_prefix("https://") is Some(rest) &&
      rest.split_once("/") is Some((host, path)) else {
      fail("attestation URL must be HTTPS")
    }
    let origin = "https://" + host.to_owned()
    guard origin == "https://tuf-repo.github.com" ||
      @github.actions_download_origin(origin) else {
      fail("untrusted attestation download origin")
    }
    guard !path.contains("#") &&
      !path.iter().any(c => c.to_int() < 32 || c == '\\') else {
      fail("invalid attestation download path")
    }
    let transport = @transport.native_raw_transport(
      base_url=origin,
      max_response_bytes=10485760,
      timeout_ms=30000,
    )
    let response = transport.send(
      @gh.RawRequest::new(verb="GET", path="/" + path.to_owned(), headers=[
        ("Accept", "application/octet-stream"),
      ]),
    )
    if response.status() is (301 | 302 | 303 | 307 | 308) {
      guard response
        .headers()
        .iter()
        .filter(pair => pair.0.equal_ignore_ascii_case("Location"))
        .next()
        is Some((_, location)) else {
        fail("missing attestation redirect location")
      }
      current = if location.has_prefix("/") && !location.has_prefix("//") {
        origin + location
      } else {
        location
      }
    } else {
      return response
    }
  }
  fail("attestation redirect limit reached")
}

///|
async fn attestation_save_cache(path : String, value : Json) -> Unit {
  let bytes = @utf8.encode(value.stringify())
  ignore(
    @download.to_file(
      path,
      sink => {
        let head = @gh.RawResponseHead::new(status=200)
        guard sink.headers(head) else { fail("trust cache rejected headers") }
        sink.chunk(bytes)
        @gh.RawDownloadResult::new(
          head~,
          bytes_received=bytes.length().to_int64(),
          complete=true,
        )
      },
      replace=true,
    ),
  )
}

///|
async fn load_release_trust(
  custom_root : String?,
  cache_directory : String?,
  fetch : async (String) -> @gh.RawHttpResponse,
  now_unix : Int64,
) -> Array[@attestation.TrustedMaterial] {
  if custom_root is Some(path) {
    guard @fs.kind(path) == @fs.Regular && @fs.file_size(path) <= 10485760L else {
      fail("invalid or oversized custom trusted root")
    }
    let text = @fs.read_file(path).text()
    let roots : Array[@attestation.TrustedMaterial] = []
    // gh's hidden option consumes newline-terminated JSONL records.
    let lines = text.split("\n").collect()
    for i in 0..<(lines.length() - 1) {
      roots.push(
        @attestation.TrustedMaterial::from_custom_root(@utf8.encode(lines[i])),
      )
    }
    guard !roots.is_empty() else { fail("no custom trusted root records") }
    return roots
  }
  let trust = @attestation.TufTrust::new(
    @attestation.github_tuf_bootstrap(),
    now_unix~,
  )
  let roots : Array[Json] = []
  let cache_path = cache_directory.map(path => {
    path + "/github-release-trust/state.json"
  })
  let root_cache_path = cache_directory.map(path => {
    path + "/github-release-trust/roots.json"
  })
  let mut lock : @fs.File? = None
  defer (if lock is Some(file) { file.close() })
  if cache_directory is Some(directory) {
    let directory = directory + "/github-release-trust"
    @fs.mkdir(directory, recursive=true, allow_exist=true, permission=0o700)
    guard @fs.kind(directory, follow_symlink=false) == @fs.Directory else {
      fail("invalid trust cache directory")
    }
    let path = directory + "/refresh.lock"
    if @fs.exists(path) {
      guard @fs.kind(path, follow_symlink=false) == @fs.Regular else {
        fail("invalid trust cache lock")
      }
    }
    let file = @fs.open(
      path,
      mode=ReadWrite,
      create_mode=OpenOrCreate,
      permission=0o600,
    )
    lock = Some(file)
    guard file.try_lock(Exclusive) else {
      fail("trust cache is being refreshed by another process")
    }
  }
  if cache_path is Some(path) && @fs.exists(path) {
    guard @fs.kind(path, follow_symlink=false) == @fs.Regular &&
      @fs.file_size(path) <= 10485760L else {
      fail("invalid trust cache file")
    }
    let previous = @bounded_json.parse(@fs.read_file(path).text())
    guard previous
      is {
        "roots": Array(previous_roots),
        "timestamp": String(ts),
        "snapshot": String(snapshot),
        "targets": String(targets),
        ..
      } &&
      previous_roots.length() <= 256 else {
      fail("invalid trust cache metadata")
    }
    for root in previous_roots {
      guard root is String(encoded) else { fail("invalid cached TUF root") }
      trust.rotate_root(@base64.decode(encoded))
      roots.push(root)
    }
    trust.restore_previous(
      @base64.decode(ts),
      @base64.decode(snapshot),
      @base64.decode(targets),
    )
  }
  // A newer verified root remains authoritative even if a later role failed
  // to refresh. Restore the old role metadata under its own root first, then
  // replay the durable root advances before making any network request.
  if root_cache_path is Some(path) && @fs.exists(path) {
    guard @fs.kind(path, follow_symlink=false) == @fs.Regular &&
      @fs.file_size(path) <= 10485760L else {
      fail("invalid TUF root cache")
    }
    let cached = @bounded_json.parse(@fs.read_file(path).text())
    guard cached is { "roots": Array(cached_roots), .. } &&
      cached_roots.length() <= 256 &&
      cached_roots.length() >= roots.length() else {
      fail("invalid TUF root cache chain")
    }
    for index in 0..<roots.length() {
      guard cached_roots[index] == roots[index] else {
        fail("conflicting TUF root cache chain")
      }
    }
    for index in roots.length()..<cached_roots.length() {
      guard cached_roots[index] is String(encoded) else {
        fail("invalid cached TUF root")
      }
      trust.rotate_root(@base64.decode(encoded))
      roots.push(cached_roots[index])
    }
  }
  let origin = "https://tuf-repo.github.com/"
  let mut last_root_found = false
  for _ in 0..<64 {
    let response = fetch(
      origin + (trust.root_version() + 1L).to_string() + ".root.json",
    )
    if response.status() == 404 {
      last_root_found = true
      break
    }
    guard response.status() == 200 else { fail("TUF root download failed") }
    trust.rotate_root(response.body())
    roots.push(Json(@base64.encode(response.body())))
    if root_cache_path is Some(path) {
      // Persist each cross-signed root before downloading the next role.
      // Otherwise a later network failure could forget a key revocation.
      attestation_save_cache(path, { "roots": roots })
    }
  }
  guard last_root_found else { fail("TUF root rotation limit exceeded") }
  async fn get(name : String) -> Bytes {
    let response = fetch(origin + name)
    guard response.status() == 200 else { fail("TUF metadata download failed") }
    response.body()
  }
  let ts = get("timestamp.json")
  let snapshot_version = trust.verify_timestamp(ts)
  let snapshot = get(trust.metadata_filename("snapshot.json", snapshot_version))
  let targets_version = trust.verify_snapshot(snapshot)
  let targets = get(trust.metadata_filename("targets.json", targets_version))
  trust.verify_targets(targets)
  let target = get("targets/" + trust.target_filename("trusted_root.json"))
  let material = trust.trusted_material(target)
  if root_cache_path is Some(path) && !@fs.exists(path) {
    attestation_save_cache(path, { "roots": roots })
  }
  if cache_path is Some(path) {
    attestation_save_cache(path, {
      "roots": roots,
      "timestamp": @base64.encode(ts),
      "snapshot": @base64.encode(snapshot),
      "targets": @base64.encode(targets),
    })
  }
  [material]
}
