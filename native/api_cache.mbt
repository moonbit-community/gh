///|
/// A small disk cache for successful `gh api --cache` responses.  The cache
/// format is intentionally private: the first line is JSON metadata and the
/// second line is a hexadecimal representation of the response bytes.
let api_cache_memory : Map[String, (Int64, @github.RawResponse)] = Map([])

///|
fn api_cache_duration(value : String) -> Int64? {
  guard value.length() >= 2 else { return None }
  let (number, multiplier) = if value.has_suffix("ms") {
    (value[:value.length() - 2].to_owned(), 1L)
  } else {
    let suffix = value[value.length() - 1:].to_owned()
    let multiplier : Int64 = match suffix {
      "s" => 1000L
      "m" => 60_000L
      "h" => 3_600_000L
      "d" => 86_400_000L
      _ => return None
    }
    (value[:value.length() - 1].to_owned(), multiplier)
  }
  let amount = @string.parse_int64(number) catch { _ => return None }
  guard amount > 0L else { return None }
  let milliseconds = amount * multiplier
  guard milliseconds > 0L else { return None }
  Some(milliseconds)
}

///|
fn api_cache_root() -> String? {
  match @env.get_env_var("GH_CACHE_DIR") {
    Some(value) if !value.trim().is_empty() => Some(value.trim().to_owned())
    _ =>
      match @env.get_env_var("XDG_CACHE_HOME") {
        Some(value) if !value.trim().is_empty() =>
          Some(value.trim().to_owned() + "/gh")
        _ =>
          match @env.get_env_var("HOME") {
            Some(value) if !value.trim().is_empty() =>
              Some(value.trim().to_owned() + "/.cache/gh")
            _ => None
          }
      }
  }
}

///|
fn api_cache_hex(bytes : Bytes) -> String {
  let alphabet = "0123456789abcdef"
  let out = StringBuilder()
  for byte in bytes {
    out.write_char(alphabet.get_char(byte.to_int() / 16).unwrap())
    out.write_char(alphabet.get_char(byte.to_int() % 16).unwrap())
  }
  out.to_string()
}

///|
fn api_cache_unhex(value : String) -> Bytes? {
  guard value.length() % 2 == 0 else { return None }
  let out = @buffer.Buffer()
  let hex = ch => {
    match ch {
      c if c is ('0'..<='9') => c.to_int() - '0'.to_int()
      c if c is ('a'..<='f') => c.to_int() - 'a'.to_int() + 10
      c if c is ('A'..<='F') => c.to_int() - 'A'.to_int() + 10
      _ => -1
    }
  }
  for index = 0; index < value.length(); index = index + 2 {
    let high = hex(value.get_char(index).unwrap())
    let low = hex(value.get_char(index + 1).unwrap())
    guard high >= 0 && low >= 0 else { return None }
    out.write_byte((high * 16 + low).to_byte())
  }
  Some(out.to_bytes())
}

///|
fn api_cache_key(request : @github.Request, scope : String) -> String {
  let input = StringBuilder()
  // Keep github.com and Enterprise caches separate without ever including
  // bearer credentials in filenames or metadata.
  input.write_string(scope)
  input.write_char('\n')
  input.write_string(request.verb())
  input.write_char('\n')
  input.write_string(request.url())
  input.write_char('\n')
  for (key, value) in request.query() {
    input.write_string(Json::array([Json(key), Json(value)]).stringify())
    input.write_char('\n')
  }
  for pair in request.headers() {
    let name = pair.0
    let value = pair.1
    // Authorization is deliberately omitted.  The cache is per local user
    // and a token must never become part of a filename or trace string.
    if !name.equal_ignore_ascii_case("authorization") {
      input.write_string(name)
      input.write_char(':')
      input.write_string(value)
      input.write_char('\n')
    }
  }
  match request.body() {
    Some(body) => input.write_string(api_cache_hex(body))
    None => ()
  }
  let digest = @crypto.sha256(@utf8.encode(input.to_string()))
  let out = StringBuilder()
  let alphabet = "0123456789abcdef"
  for byte in digest {
    out.write_char(alphabet.get_char(byte.to_int() / 16).unwrap())
    out.write_char(alphabet.get_char(byte.to_int() % 16).unwrap())
  }
  out.to_string()
}

///|
fn api_cache_path(request : @github.Request, scope : String) -> String? {
  api_cache_root().map(root => {
    root + "/api-" + api_cache_key(request, scope) + ".cache"
  })
}

///|
async fn api_cache_read(
  request : @github.Request,
  duration : String,
  scope : String,
) -> @github.RawResponse? {
  let ttl = match api_cache_duration(duration) {
    Some(value) => value
    None => return None
  }
  let key = api_cache_key(request, scope)
  let memory_key = key + "\u{0}" + duration
  let now = UInt64::reinterpret_as_int64(@env.now())
  match api_cache_memory.get(memory_key) {
    Some((created, response)) if now >= created && now - created <= ttl =>
      return Some(response)
    _ => ()
  }
  let path = match api_cache_path(request, scope) {
    Some(value) => value
    None => return None
  }
  let now = UInt64::reinterpret_as_int64(@env.now())
  let seconds = now / 1000L
  let millis = now % 1000L
  let current = seconds * 1000L + millis
  let (mtime, _) = @fs.mtime(path, follow_symlink=false) catch {
    _ => return None
  }
  guard current >= mtime * 1000L && current - mtime * 1000L <= ttl else {
    return None
  }
  let text = @fs.read_file(path).text() catch { _ => return None }
  let newline = match text.find("\n") {
    Some(value) => value
    None => return None
  }
  let metadata : Json = @json.parse(text[:newline].to_owned()) catch {
    _ => return None
  }
  let body = match api_cache_unhex(text[newline + 1:].to_owned()) {
    Some(value) => value
    None => return None
  }
  match metadata {
    { "status": Number(status, ..), "headers": Array(headers), .. } => {
      let parsed_headers : Array[(String, String)] = []
      for header in headers {
        match header {
          Array([String(name), String(value)]) =>
            parsed_headers.push((name, value))
          _ => return None
        }
      }
      let response = @github.RawResponse::new(
        status=status.to_int(),
        headers=parsed_headers,
        body~,
        reason_phrase?=match metadata {
          { "reason_phrase": String(value), .. } => Some(value)
          _ => None
        },
      )
      api_cache_memory[memory_key] = (now, response)
      Some(response)
    }
    _ => None
  }
}

///|
async fn api_cache_write(
  request : @github.Request,
  response : @github.RawResponse,
  duration : String,
  scope : String,
) -> Unit {
  api_cache_memory[api_cache_key(request, scope) + "\u{0}" + duration] = (
    UInt64::reinterpret_as_int64(@env.now()),
    response,
  )
  let path = match api_cache_path(request, scope) {
    Some(value) => value
    None => return
  }
  let root = match api_cache_root() {
    Some(value) => value
    None => return
  }
  @fs.mkdir(root, recursive=true) catch {
    _ => return
  }
  let headers = response
    .headers()
    .map(pair => Json::array([Json(pair.0), Json(pair.1)]))
  let metadata : Json = {
    "status": Json(response.status()),
    "headers": Json::array(headers),
    "reason_phrase": response
    .reason_phrase()
    .map_or(Json::null(), value => Json(value)),
  }
  let text = metadata.stringify() + "\n" + api_cache_hex(response.body())
  @fs.write_file(path, @utf8.encode(text), permission=0o600) catch {
    _ => ()
  }
}
