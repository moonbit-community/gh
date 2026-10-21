///|
/// Opt-in acceptance protection is checked immediately before each network
/// request. Normal product use does not load a test policy or alter behavior.
async fn check_acceptance_request(
  policy_path : String?,
  origin : String,
  request : @gh.RawRequest,
) -> Unit {
  guard policy_path is Some(path) else { return }
  guard request.stream() is None else { raise InvalidRequest }
  guard !path.is_empty() &&
    @fs.kind(path) == @fs.Regular &&
    @fs.file_size(path) <= 262144L else {
    raise InvalidRequest
  }
  let source = @fs.read_file(path).text()
  let policy = @live_scope.Policy::from_json(@json.parse(source))
  guard policy.allows(
    origin,
    request.verb(),
    request.path(),
    request.body(),
    now_ms=UInt64::reinterpret_as_int64(@env.now()),
  ) else {
    raise InvalidRequest
  }
  if request.verb() is ("POST" | "PUT" | "PATCH" | "DELETE") {
    // Read-only GraphQL has no mutation permit. Only actual approved writes
    // consume an exclusive receipt before opening any network connection.
    let read_policy = @live_scope.Policy::from_json({
      "schema": 1,
      "permits": [],
    })
    if !read_policy.allows(
        origin,
        request.verb(),
        request.path(),
        request.body(),
      ) {
      guard @json.parse(source) is { "request_id": String(nonce), .. } &&
        nonce.length() == 32 &&
        nonce.iter().all(ch => ch is ('0'..<='9' | 'a'..<='f')) else {
        raise InvalidRequest
      }
      let digest = @crypto.bytes_to_hex_string(
        @crypto.sha256(
          @utf8.encode(origin + "\n" + request.verb() + "\n" + request.path()) +
          request.body().unwrap_or(b""),
        ),
      )
      // CreateNew rejects a replay, including concurrent duplicate sends.
      @fs.write_file(
        path + "." + nonce + "." + digest + ".claimed",
        "",
        create_mode=CreateNew,
        permission=0o600,
      ) catch {
        _ => raise InvalidRequest
      }
    }
  }
}
