///|
/// This error deliberately contains only static, non-sensitive diagnostics.
priv suberror NativeTransportFailure {
  InvalidConfiguration
  InvalidRequest
  ResponseTooLarge
  UnsupportedEncoding
  InvalidTextResponse
}

///|
/// Construct a transport bound to one HTTPS origin, or loopback HTTP for local
/// development. Each send opens and closes its own connection. Redirects are
/// returned to the caller without following them, and requests are never retried.
/// The timeout covers connection establishment, request writing, and body reads.
pub fn native_transport(
  base_url~ : String,
  timeout_ms? : Int = 30000,
  max_response_bytes? : Int = 8388608,
) -> @gh.Transport raise {
  guard timeout_ms > 0 && max_response_bytes > 0 else {
    raise InvalidConfiguration
  }
  let origin = match @gh.normalize_origin(base_url) {
    Ok(origin) => origin
    Err(_) => raise InvalidConfiguration
  }
  @gh.Transport::new(origin~, send=request => {
    guard @gh.valid_request_path(request.path) else { raise InvalidRequest }
    let headers = request_headers(request.headers)
    @async.with_timeout(timeout_ms) <| () => {
      let client = @http.Client(origin, headers~)
      defer client.close()
      let body = match request.body {
        Some(body) => @utf8.encode(body)
        None => b""
      }
      client.request(native_method(request.verb), request.path, extra_headers={
        "Content-Length": body.length().to_string(),
      })
      if body.length() > 0 {
        client.write(body)
      }
      let response = client.end_request()
      if response.headers.get("Content-Encoding") is Some(encoding) &&
        encoding.trim().to_owned().to_lower() != "identity" {
        raise UnsupportedEncoding
      }
      let buffer = @buffer.Buffer()
      for ;; {
        let remaining = max_response_bytes - buffer.length()
        // Read one extra byte at the limit to distinguish EOF from truncation.
        let read_size = if remaining == 0 {
          1
        } else if remaining < 8192 {
          remaining
        } else {
          8192
        }
        match client.read_some(max_len=read_size) {
          None => break
          Some(bytes) => {
            guard bytes.length() <= remaining else { raise ResponseTooLarge }
            buffer.write_bytes(bytes)
          }
        }
      }
      let body = @utf8.decode(buffer.to_bytes()) catch {
        _ => raise InvalidTextResponse
      }
      let headers = response.headers
        .iter()
        .map(fn(pair) {
          let (name, value) = pair
          (name.0, value)
        })
        .collect()
      @gh.Response::new(status=response.code, body~, headers~)
    }
  })
}

///|
fn native_method(verb : @gh.HttpMethod) -> @http.RequestMethod {
  match verb {
    Get => Get
    Post => Post
    Put => Put
    Patch => Patch
    Delete => Delete
  }
}

///|
fn request_headers(values : Array[(String, String)]) -> @http.Headers raise {
  let headers : @http.Headers = Map([])
  for (name, value) in values {
    guard !name.is_empty() else { raise InvalidRequest }
    for char in name {
      guard char
        is ('a'..='z'
        | 'A'..='Z'
        | '0'..='9'
        | '!'
        | '#'
        | '$'
        | '%'
        | '&'
        | '\''
        | '*'
        | '+'
        | '-'
        | '.'
        | '^'
        | '_'
        | '`'
        | '|'
        | '~') else {
        raise InvalidRequest
      }
    }
    for char in value {
      guard char >= ' ' && char != '\u{7f}' else { raise InvalidRequest }
    }
    let name = @http.CaseInsensitiveString(name)
    guard !(name == "Host" ||
      name == "Content-Length" ||
      name == "Transfer-Encoding" ||
      name == "Connection" ||
      name == "Proxy-Connection" ||
      name == "Proxy-Authorization" ||
      name == "Upgrade" ||
      name == "Expect" ||
      headers.contains(name)) else {
      raise InvalidRequest
    }
    if name == "Accept-Encoding" && value != "identity" {
      raise InvalidRequest
    }
    headers[name] = value
  }
  // Bound the received representation directly; no implicit decompression.
  headers["Accept-Encoding"] = "identity"
  headers["Connection"] = "close"
  if !headers.contains("User-Agent") {
    headers["User-Agent"] = "moonhub-gh/0.1.0"
  }
  headers
}
