///|
/// Byte-preserving request for arbitrary HTTP methods and binary payloads.
/// Provider policy lives above this transport boundary.
pub struct RawRequest {
  verb : String
  path : String
  headers : Array[(String, String)]
  body : Bytes?
  priv body_stream : RawBodyStream?
}

///|
pub fn RawRequest::new(
  verb~ : String,
  path~ : String,
  headers~ : Array[(String, String)] = [],
  body? : Bytes,
) -> RawRequest {
  { verb, path, headers: headers.copy(), body, body_stream: None, }
}

///|
/// A single-use streaming body. Each callback returns a nonempty chunk, or
/// None at EOF. The caller owns its file/stdin resource and must keep it open
/// until send completes. The transport never retries or rewinds this stream.
pub struct RawBodyStream {
  length : Int32?
  priv next_chunk : async () -> Bytes?
}

///|
pub fn RawBodyStream::new(
  next~ : async () -> Bytes?,
  length? : Int32,
) -> RawBodyStream {
  { length, next_chunk: next, }
}

///|
pub async fn RawBodyStream::next(self : RawBodyStream) -> Bytes? {
  (self.next_chunk)()
}

///|
pub fn RawBodyStream::length(self : RawBodyStream) -> Int32? {
  self.length
}

///|
/// Supply a file, stdin, or generated stream without buffering its entire body.
/// Unknown lengths use chunked transfer; known lengths are checked at EOF.
pub fn RawRequest::from_stream(
  verb~ : String,
  path~ : String,
  stream~ : RawBodyStream,
  headers~ : Array[(String, String)] = [],
) -> RawRequest {
  {
    verb,
    path,
    headers: headers.copy(),
    body: None,
    body_stream: Some(stream),
  }
}

///|
pub fn RawRequest::stream(self : RawRequest) -> RawBodyStream? {
  self.body_stream
}

///|
pub fn RawRequest::verb(self : RawRequest) -> String {
  self.verb
}

///|
pub fn RawRequest::path(self : RawRequest) -> String {
  self.path
}

///|
pub fn RawRequest::headers(self : RawRequest) -> Array[(String, String)] {
  self.headers.copy()
}

///|
pub fn RawRequest::body(self : RawRequest) -> Bytes? {
  self.body
}

///|
/// A response whose status, duplicate headers and bytes are retained exactly
/// as supplied by the transport adapter.  Empty and non-JSON bodies are valid.
pub struct RawHttpResponse {
  status : Int32
  headers : Array[(String, String)]
  body : Bytes
}

///|
pub fn RawHttpResponse::new(
  status~ : Int32,
  headers~ : Array[(String, String)] = [],
  body~ : Bytes = b"",
) -> RawHttpResponse {
  { status, headers: headers.copy(), body, }
}

///|
pub fn RawHttpResponse::status(self : RawHttpResponse) -> Int32 {
  self.status
}

///|
pub fn RawHttpResponse::headers(
  self : RawHttpResponse,
) -> Array[(String, String)] {
  self.headers.copy()
}

///|
pub fn RawHttpResponse::body(self : RawHttpResponse) -> Bytes {
  self.body
}

///|
pub fn RawHttpResponse::header(
  self : RawHttpResponse,
  name : String,
) -> String? {
  for (key, value) in self.headers {
    if key.equal_ignore_ascii_case(name) {
      return Some(value)
    }
  }
  None
}

///|
/// Provider-neutral transport boundary.  The callback owns timeout,
/// cancellation and platform I/O policy; this layer performs no retries or
/// redirects and never decodes the response body.
pub struct RawTransport {
  origin : String
  priv send_request : async (RawRequest) -> RawHttpResponse
}

///|
pub fn RawTransport::new(
  origin~ : String,
  send~ : async (RawRequest) -> RawHttpResponse,
) -> RawTransport {
  { origin, send_request: send, }
}

///|
pub fn RawTransport::origin(self : RawTransport) -> String {
  self.origin
}

///|
pub async fn RawTransport::send(
  self : RawTransport,
  request : RawRequest,
) -> RawHttpResponse {
  (self.send_request)(request)
}
