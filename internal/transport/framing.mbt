///|
// These limits apply during parsing, including unterminated lines, duplicate
// headers, cookies and trailers. The body buffer has its own independent cap.
async fn read_response(
  client : @http.Client,
  verb : @gh.HttpMethod,
  max_response_bytes : Int,
) -> @gh.Response {
  let decoder = @http1.ResponseDecoder::new(
    native_method(verb),
    limits={
      max_start_line: 8192,
      max_header_line: 8192,
      max_header_count: 100,
      max_header_bytes: 65536,
      max_body_bytes: max_response_bytes,
      max_buffer_bytes: 16384,
    },
  )
  let buffer = @buffer.Buffer()
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
            (field.name.value == "transfer-encoding" ||
            (field.name.value == "content-length" &&
              (encoding.is_empty() || !encoding.iter().all(c => c == '0')))) {
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
