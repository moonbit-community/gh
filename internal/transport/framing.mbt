///|
// These limits apply during parsing, including unterminated lines, duplicate
// headers, cookies and trailers. The body buffer has its own independent cap.
async fn read_response(
  client : @http.Client,
  verb : @gh.HttpMethod,
  max_response_bytes : Int32,
) -> @gh.Response {
  let decoder = @http1.ResponseDecoder::new(
    native_method(verb),
    limits=response_limits(max_response_bytes),
  )
  let buffer = @buffer.Buffer()
  let line_guard = ResponseLineGuard::new()
  let mut head : @http_types.Response[Unit]? = None
  let mut eof = false
  for ;; {
    let event = match decoder.next() {
      Ok(event) => event
      Err(error) => raise error
    }
    match event {
      Some(ResponseHead(value)) => {
        // This client does not request Continue or protocol upgrades.
        guard value.status >= 200 else {
          raise @http1.InvalidFraming("unsupported informational response")
        }
        for field in value.headers.fields() {
          let encoding = @utf8.decode(field.value.bytes) catch {
            _ => raise InvalidTextResponse
          }
          if field.name.value == "content-encoding" &&
            encoding.trim().to_owned().to_lower() != "identity" {
            raise UnsupportedEncoding
          }
          if field.name.value == "transfer-encoding" &&
            encoding.trim().to_owned().to_lower() != "chunked" {
            raise UnsupportedEncoding
          }
          // The codec treats 204 as bodyless before checking framing. Do
          // not let an advertised body become a successful empty mutation.
          if value.status == 204 &&
            (
              field.name.value == "transfer-encoding" ||
              (
                field.name.value == "content-length" &&
                (encoding.is_empty() || !encoding.iter().all(c => c == '0'))
              )
            ) {
            raise @http1.InvalidFraming("204 response advertises a body")
          }
        }
        // Preserve the previous adapter's immediate empty 205 when the
        // server omits framing, even if it keeps the connection open.
        if value.status == 205 &&
          value.headers.get_string("content-length") is None &&
          value.headers.get_string("transfer-encoding") is None {
          return response_from_head(value, b"")
        }
        head = Some(value)
      }
      Some(ResponseData(bytes)) => {
        guard bytes.length() <= max_response_bytes - buffer.length() else {
          raise ResponseTooLarge
        }
        buffer.write_bytes(bytes)
      }
      // Trailers are parsed under independent limits but never used as
      // response metadata (ETag, request id, encoding or cookies).
      Some(ResponseTrailers(_)) => ()
      Some(ResponseEnd) => {
        guard head is Some(head) else {
          raise @http1.UnexpectedEof("response head")
        }
        return response_from_head(head, buffer.to_bytes())
      }
      None => {
        guard !eof else { raise @http1.UnexpectedEof("response") }
        let bytes = match client.read_some(max_len=8192) {
          Some(bytes) => bytes
          None => {
            eof = true
            b""
          }
        }
        line_guard.feed(bytes[:])
        match decoder.feed(bytes[:]) {
          Ok(_) => ()
          Err(error) => raise error
        }
        if eof {
          decoder.finish_input()
        }
      }
    }
  }
}

///|
/// MoonbitHTTP 0.7 measures a line against its backing buffer before that
/// buffer is compacted. Keep its internal allowance above the wire policy and
/// enforce the 8 KiB status/header/trailer limit at the transport boundary.
/// The guard understands chunked framing so binary fixed-length bodies remain
/// opaque.
priv struct ResponseLineGuard {
  mut status_line : Bool
  mut informational : Bool
  mut line_length : Int32
  mut pending_cr : Bool
  mut phase : Int32
  mut chunked : Bool
  mut line_bytes : Array[Byte]
  mut chunk_remaining : Int32
  mut chunk_crlf_step : Int32
}

///|
fn ResponseLineGuard::new() -> ResponseLineGuard {
  {
    status_line: true,
    informational: false,
    line_length: 0,
    pending_cr: false,
    phase: 0,
    chunked: false,
    line_bytes: [],
    chunk_remaining: 0,
    chunk_crlf_step: 0,
  }
}

///|
fn ResponseLineGuard::feed(
  self : ResponseLineGuard,
  bytes : BytesView,
) -> Unit raise {
  for byte in bytes {
    if self.phase == 1 {
      continue
    }
    if self.phase == 3 {
      self.chunk_remaining -= 1
      if self.chunk_remaining == 0 {
        self.phase = 4
      }
      continue
    }
    if self.phase == 4 {
      if self.chunk_crlf_step == 0 {
        guard byte == b'\r' else {
          raise @http1.InvalidFraming("chunk data is not followed by CRLF")
        }
        self.chunk_crlf_step = 1
      } else {
        guard byte == b'\n' else {
          raise @http1.InvalidFraming("chunk data is not followed by CRLF")
        }
        self.chunk_crlf_step = 0
        self.phase = 2
      }
      continue
    }
    if self.pending_cr {
      if byte == b'\n' {
        guard self.line_length <= 8192 else {
          raise @http1.LimitExceeded("response line")
        }
        if self.status_line {
          self.informational = guard_status_is_informational(self.line_bytes)
          self.status_line = false
          self.line_length = 0
          self.line_bytes = []
          self.pending_cr = false
          continue
        }
        if self.phase == 0 {
          if self.line_length == 0 {
            if self.informational {
              self.status_line = true
              self.informational = false
              self.phase = 0
              self.chunked = false
            } else {
              self.phase = if self.chunked { 2 } else { 1 }
            }
          } else {
            let text = @utf8.decode(Bytes::from_array(self.line_bytes)) catch {
              _ => ""
            }
            let normalized = text.to_lower()
            if normalized.contains("transfer-encoding:") &&
              normalized.contains("chunked") {
              self.chunked = true
            }
          }
        } else if self.phase == 2 {
          let size = parse_guard_chunk_size(self.line_bytes)
          self.phase = if size == 0 { 5 } else { 3 }
          self.chunk_remaining = size
        } else if self.phase == 5 && self.line_length == 0 {
          self.phase = 1
        }
        self.line_length = 0
        self.line_bytes = []
        self.pending_cr = false
        continue
      }
      self.line_length += 1
      self.line_bytes.push(b'\r')
      self.pending_cr = false
    }
    if byte == b'\r' {
      self.pending_cr = true
    } else {
      self.line_length += 1
      self.line_bytes.push(byte)
      guard self.line_length <= 8192 else {
        raise @http1.LimitExceeded("response line")
      }
    }
  }
}

///|
fn parse_guard_chunk_size(line : Array[Byte]) -> Int32 raise {
  let mut size = 0
  let mut digits = 0
  for byte in Bytes::from_array(line) {
    if byte == b';' || byte == b' ' || byte == b'\t' {
      break
    }
    let value = if byte >= b'0' && byte <= b'9' {
      byte.to_int() - 48
    } else if byte >= b'a' && byte <= b'f' {
      byte.to_int() - 87
    } else if byte >= b'A' && byte <= b'F' {
      byte.to_int() - 55
    } else {
      raise @http1.InvalidFraming("invalid chunk size")
    }
    guard size <= (0x7fffffff - value) / 16 else {
      raise @http1.InvalidFraming("invalid chunk size")
    }
    size = size * 16 + value
    digits += 1
  }
  guard digits > 0 else { raise @http1.InvalidFraming("invalid chunk size") }
  size
}

///|
fn guard_status_is_informational(line : Array[Byte]) -> Bool {
  line.length() >= 12 &&
  line[9] == b'1' &&
  line[10] >= b'0' &&
  line[10] <= b'9' &&
  line[11] >= b'0' &&
  line[11] <= b'9'
}

///|
/// Build the bounded HTTP/1 parser configuration used by the text adapter.
/// MoonbitHTTP 0.7 exposes `Limits` through a validating constructor rather
/// than a record literal; all values here are fixed-valid except the caller's
/// response cap, which is checked by `native_transport` before this point.
fn response_limits(max_response_bytes : Int32) -> @http_types.Limits raise {
  match
    @http_types.Limits::new(
      max_start_line=16384,
      max_header_line=16384,
      max_header_count=100,
      max_header_bytes=65536,
      max_body_bytes=max_response_bytes,
      max_buffer_bytes=16384,
    ) {
    Ok(limits) => limits
    Err(_) => raise @http1.LimitExceeded("invalid response limits")
  }
}

///|
fn response_from_head(
  head : @http_types.Response[Unit],
  bytes : Bytes,
) -> @gh.Response raise {
  let body = @utf8.decode(bytes) catch { _ => raise InvalidTextResponse }
  let combined : @http.Headers = Map([])
  for field in head.headers.fields() {
    if field.name.value == "set-cookie" {
      continue
    }
    let name = @http.CaseInsensitiveString(field.name.value)
    let value = @utf8.decode(field.value.bytes) catch {
      _ => raise InvalidTextResponse
    }
    combined[name] = match combined.get(name) {
      None => value
      Some(previous) => previous + ", " + value
    }
  }
  let headers = combined.iter().map(pair => (pair.0.0, pair.1)).collect()
  @gh.Response::new(status=head.status, body~, headers~)
}
