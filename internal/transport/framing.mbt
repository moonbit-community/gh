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
  mut reason_phrase : String?
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
    reason_phrase: None,
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
          if !self.informational && self.line_bytes.length() >= 12 {
            let reason = Bytes::from_array(self.line_bytes)[12:]
            let text = StringBuilder()
            // HTTP/1 reason phrases are opaque octets; retain non-ASCII
            // bytes without replacing them or reading body data as text.
            for byte in reason {
              text.write_char(byte.to_int().to_char().unwrap())
            }
            self.reason_phrase = Some(
              text
              .to_string()
              .strip_prefix(" ")
              .map_or(text.to_string(), value => value.to_owned()),
            )
          }
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
/// Build the bounded HTTP/1 parser configuration used by the raw adapter.
/// MoonbitHTTP 0.7 exposes `Limits` through a validating constructor rather
/// than a record literal; all values here are fixed-valid except the caller's
/// response cap, which is checked by `native_raw_transport` before this point.
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
