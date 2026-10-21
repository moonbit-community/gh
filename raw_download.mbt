///|
/// Response metadata delivered before any body chunks. Duplicate headers and
/// their order are preserved; no provider authentication policy belongs here.
pub struct RawResponseHead {
  status : Int32
  reason_phrase : String?
  headers : Array[(String, String)]
}

///|
pub fn RawResponseHead::new(
  status~ : Int32,
  headers~ : Array[(String, String)] = [],
  reason_phrase? : String,
) -> RawResponseHead {
  { status, reason_phrase, headers: headers.copy(), }
}

///|
pub fn RawResponseHead::reason_phrase(self : RawResponseHead) -> String? {
  self.reason_phrase
}

///|
pub fn RawResponseHead::status(self : RawResponseHead) -> Int32 {
  self.status
}

///|
pub fn RawResponseHead::headers(
  self : RawResponseHead,
) -> Array[(String, String)] {
  self.headers.copy()
}

///|
pub fn RawResponseHead::header(
  self : RawResponseHead,
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
/// The headers callback can decline the body (for example on a redirect).
/// Data callbacks run sequentially and are awaited, providing backpressure.
/// Raising or cancelling either callback closes the transport's connection.
pub struct RawResponseSink {
  priv on_headers : async (RawResponseHead) -> Bool
  priv on_chunk : async (Bytes) -> Unit
}

///|
pub fn RawResponseSink::new(
  headers~ : async (RawResponseHead) -> Bool,
  chunk~ : async (Bytes) -> Unit,
) -> RawResponseSink {
  { on_headers: headers, on_chunk: chunk, }
}

///|
pub async fn RawResponseSink::headers(
  self : RawResponseSink,
  head : RawResponseHead,
) -> Bool {
  (self.on_headers)(head)
}

///|
pub async fn RawResponseSink::chunk(
  self : RawResponseSink,
  bytes : Bytes,
) -> Unit {
  (self.on_chunk)(bytes)
}

///|
pub struct RawDownloadResult {
  head : RawResponseHead
  bytes_received : Int64
  complete : Bool
}

///|
pub fn RawDownloadResult::new(
  head~ : RawResponseHead,
  bytes_received~ : Int64,
  complete~ : Bool,
) -> RawDownloadResult {
  { head, bytes_received, complete, }
}

///|
pub fn RawDownloadResult::head(self : RawDownloadResult) -> RawResponseHead {
  self.head
}

///|
pub fn RawDownloadResult::bytes_received(self : RawDownloadResult) -> Int64 {
  self.bytes_received
}

///|
pub fn RawDownloadResult::complete(self : RawDownloadResult) -> Bool {
  self.complete
}

///|
/// Stream while the transport owns the connection. Older injected transports
/// remain compatible through a buffered fallback; native adapters supply the
/// streaming callback and keep their normal API buffering limit unchanged.
pub async fn RawTransport::receive(
  self : RawTransport,
  request : RawRequest,
  sink : RawResponseSink,
) -> RawDownloadResult {
  if self.receive_request is Some(receive) {
    return receive(request, sink)
  }
  let response = self.send(request)
  let head = RawResponseHead::new(
    status=response.status(),
    headers=response.headers(),
    reason_phrase?=response.reason_phrase(),
  )
  if !sink.headers(head) {
    return RawDownloadResult::new(head~, bytes_received=0L, complete=false)
  }
  if !response.body().is_empty() {
    sink.chunk(response.body())
  }
  RawDownloadResult::new(
    head~,
    bytes_received=response.body().length().to_int64(),
    complete=true,
  )
}

///|
pub fn RawTransport::supports_streaming(self : RawTransport) -> Bool {
  self.receive_request is Some(_)
}
