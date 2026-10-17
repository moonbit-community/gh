///|
/// Construct a byte-preserving HTTP transport scoped to one HTTPS origin or
/// explicit loopback HTTP origin. Every send opens one connection. Redirects
/// and all HTTP status codes return untouched; requests are never retried.
/// Timeout and task cancellation cover connection, stream reads and response.
/// Response bytes are not UTF-8 decoded or automatically decompressed.
pub fn native_raw_transport(
  base_url~ : String,
  timeout_ms~ : Int32 = 30000,
  max_response_bytes~ : Int32 = 8388608,
) -> @gh.RawTransport raise {
  guard timeout_ms > 0 && max_response_bytes > 0 else {
    raise InvalidConfiguration
  }
  let origin = match @gh.normalize_origin(base_url) {
    Ok(value) => value
    Err(_) => raise InvalidConfiguration
  }
  @gh.RawTransport::new(origin~, send=request => {
    let verb = raw_method(request.verb)
    guard raw_valid_path(request.path) else { raise InvalidRequest }
    let fields = raw_request_headers(request.headers, origin)
    let framing : @http1.BodyFraming = match request.stream() {
      Some(stream) =>
        match stream.length() {
          Some(length) if length >= 0 => ContentLength(length)
          Some(_) => raise InvalidRequest
          None => Chunked
        }
      None =>
        match request.body {
          Some(body) => ContentLength(body.length())
          None => NoBody
        }
    }
    let uri = match @http_types.Uri::parse_request_target(request.path, verb) {
      Ok(uri) => uri
      Err(_) => raise InvalidRequest
    }
    let head = match
      @http1.encode_request_head(
        { http_method: verb, uri, version: Http11, headers: fields, body: (), },
        framing,
      ) {
      Ok(bytes) => bytes
      Err(_) => raise InvalidRequest
    }
    @async.with_timeout(timeout_ms) <| () => {
      let client = @http.Client(origin)
      defer client.close()
      client.enter_passthrough_mode()
      client.write(head)
      match request.stream() {
        Some(stream) => raw_write_stream(client, stream, framing)
        None =>
          match request.body {
            Some(body) if !body.is_empty() => client.write(body)
            _ => ()
          }
      }
      read_raw_response(client, verb, max_response_bytes)
    }
  })
}

///|
/// Adapt an upstream async reader, including a file or stdin, into a bounded
/// sequence of body chunks. Ownership and closing remain with the caller.
pub fn raw_body_from_reader(
  reader : &@io.Reader,
  length? : Int32,
) -> @gh.RawBodyStream {
  @gh.RawBodyStream::new(next=() => reader.read_some(max_len=65536), length?)
}

///|
fn raw_method(value : String) -> @http_types.Method raise {
  guard !value.is_empty() &&
    value
    .iter()
    .all(ch => {
      ch is ('a'..<='z' | 'A'..<='Z' | '0'..<='9') ||
      "!#$%&'*+-.^_`|~".contains_char(ch)
    }) else {
    raise InvalidRequest
  }
  match value {
    "GET" => Get
    "POST" => Post
    "PUT" => Put
    "DELETE" => Delete
    "HEAD" => Head
    "OPTIONS" => Options
    "PATCH" => Patch
    "TRACE" => Trace
    "CONNECT" => Connect
    value => Extension(value)
  }
}

///|
fn raw_valid_path(path : String) -> Bool {
  guard path.has_prefix("/") &&
    !path.has_prefix("//") &&
    !path.contains_char('#') &&
    !path.contains_char('\\') &&
    path.iter().all(ch => ch.to_int() > 32 && ch.to_int() < 127) else {
    return false
  }
  // Keep the path opaque (GitHub uses encoded slashes in a few APIs), while
  // rejecting escapes that can turn into control characters, backslashes, or
  // dot segments when an intermediary decodes them before routing.
  let route = path.split_once("?").map_or(path, pair => pair.0.to_owned())
  let lowered = route.to_lower()
  if lowered.contains("%00") ||
    lowered.contains("%0d") ||
    lowered.contains("%0a") ||
    lowered.contains("%5c") {
    return false
  }
  let decoded_dots = lowered.replace_all(old="%2e", new=".")
  if decoded_dots.split("/").any(part => part == "." || part == "..") {
    return false
  }
  // A malformed percent escape must never reach the HTTP codec.  It would be
  // interpreted differently by different servers and proxies.
  let mut cursor = 0
  while cursor < path.length() {
    if path[cursor] == '%' {
      guard cursor + 2 < path.length() &&
        path[cursor + 1] is ('a'..<='f' | 'A'..<='F' | '0'..<='9') &&
        path[cursor + 2] is ('a'..<='f' | 'A'..<='F' | '0'..<='9') else {
        return false
      }
      cursor += 3
    } else {
      cursor += 1
    }
  }
  true
}

///|
fn raw_request_headers(
  headers : Array[(String, String)],
  origin : String,
) -> @http_types.HeaderMap raise {
  let fields = @http_types.HeaderMap::new()
  for (name, value) in headers {
    match name.to_lower() {
      "host"
      | "content-length"
      | "transfer-encoding"
      | "connection"
      | "proxy-connection"
      | "proxy-authorization"
      | "upgrade"
      | "expect" => raise InvalidRequest
      _ => ()
    }
    match fields.append_string(name, value) {
      Ok(_) => ()
      Err(_) => raise InvalidRequest
    }
  }
  ignore(
    fields.append_string("Host", origin.split_once("://").unwrap().1.to_owned()),
  )
  ignore(fields.append_string("Connection", "close"))
  if fields.get_string("accept-encoding") is None {
    ignore(fields.append_string("Accept-Encoding", "identity"))
  }
  if fields.get_string("user-agent") is None {
    ignore(fields.append_string("User-Agent", "gh-moonbit/0.1.0"))
  }
  fields
}

///|
async fn raw_write_stream(
  client : @http.Client,
  stream : @gh.RawBodyStream,
  framing : @http1.BodyFraming,
) -> Unit {
  let mut remaining = stream.length()
  for ;; {
    match stream.next() {
      None => break
      Some(bytes) => {
        // Empty chunks violate the progress contract and would permit an
        // infinite non-yielding producer to evade the request deadline.
        guard !bytes.is_empty() else { raise InvalidRequest }
        if remaining is Some(length) {
          guard bytes.length() <= length else { raise InvalidRequest }
          remaining = Some(length - bytes.length())
        }
        let encoded = match @http1.encode_body_data(bytes, framing) {
          Ok(value) => value
          Err(_) => raise InvalidRequest
        }
        client.write(encoded)
      }
    }
  }
  guard remaining is None || remaining == Some(0) else { raise InvalidRequest }
  let ending = match @http1.encode_body_end(framing) {
    Ok(value) => value
    Err(_) => raise InvalidRequest
  }
  if !ending.is_empty() {
    client.write(ending)
  }
}
