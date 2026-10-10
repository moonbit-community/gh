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
      let client = @http.Client(origin)
      defer client.close()
      // Switch while the client is still clean. DNS/TLS remain upstream; all
      // HTTP framing passes through the bounded community codec below.
      client.enter_passthrough_mode()
      let body = match request.body {
        Some(body) => @utf8.encode(body)
        None => b""
      }
      let fields = @http_types.HeaderMap::new()
      for (name, value) in headers {
        match fields.append_string(name.0, value) {
          Ok(_) => ()
          Err(_) => raise InvalidRequest
        }
      }
      let authority = origin.split_once("://").unwrap().1.to_owned()
      ignore(fields.append_string("Host", authority))
      let head = @http1.encode_request_head(
        {
          http_method: native_method(request.verb),
          uri: { value: request.path },
          version: Http11,
          headers: fields,
          body: (),
        },
        ContentLength(body.length()),
      )
      match head {
        Ok(bytes) => client.write(bytes)
        Err(error) => raise error
      }
      if body.length() > 0 {
        client.write(body)
      }
      read_response(client, request.verb, max_response_bytes)
    }
  })
}

///|
fn native_method(verb : @gh.HttpMethod) -> @http_types.Method {
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
