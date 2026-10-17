///|
async fn read_raw_response(
  client : @http.Client,
  verb : @http_types.Method,
  max_response_bytes : Int32,
) -> @gh.RawHttpResponse {
  let decoder = @http1.ResponseDecoder::new(
    verb,
    limits=response_limits(max_response_bytes),
  )
  let buffer = @buffer.Buffer()
  let line_guard = ResponseLineGuard::new()
  let mut head : @http_types.Response[Unit]? = None
  let mut eof = false
  let mut informational_count = 0
  for ;; {
    let event = match decoder.next() {
      Ok(value) => value
      Err(error) => raise error
    }
    match event {
      Some(ResponseHead(value)) => {
        if value.status == 101 ||
          (verb is Connect && value.status >= 200 && value.status < 300) {
          raise @http1.InvalidFraming("protocol upgrade is unsupported")
        }
        if value.status < 200 {
          informational_count += 1
          guard informational_count <= 16 else {
            raise @http1.LimitExceeded("informational responses")
          }
          head = None
          continue
        }
        // A 204 cannot advertise an entity. HEAD/304 may advertise the
        // representation length while returning an empty response body.
        if value.status == 204 {
          for field in value.headers.fields() {
            if field.name.value == "transfer-encoding" ||
              (
                field.name.value == "content-length" &&
                (
                  field.value.bytes.is_empty() ||
                  !field.value.bytes.iter().all(byte => byte == b'0')
                )
              ) {
              raise @http1.InvalidFraming("204 response advertises a body")
            }
          }
        }
        if @http_types.response_allows_body(verb, value.status) {
          for field in value.headers.fields() {
            if field.name.value == "transfer-encoding" &&
              field.value.to_string_lossy().trim().to_owned().to_lower() !=
              "chunked" {
              raise UnsupportedEncoding
            }
          }
        }
        head = Some(value)
        if value.status == 205 &&
          value.headers.get_string("content-length") is None &&
          value.headers.get_string("transfer-encoding") is None {
          return raw_response_from_head(value, b"")
        }
      }
      Some(ResponseData(bytes)) => {
        guard head is Some(_) else {
          raise @http1.InvalidFraming("data before final response")
        }
        guard bytes.length() <= max_response_bytes - buffer.length() else {
          raise ResponseTooLarge
        }
        buffer.write_bytes(bytes)
      }
      // Trailer fields are not promoted into response headers.
      Some(ResponseTrailers(_)) => ()
      Some(ResponseEnd) =>
        match head {
          Some(value) => return raw_response_from_head(value, buffer.to_bytes())
          None => ()
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
fn raw_response_from_head(
  head : @http_types.Response[Unit],
  body : Bytes,
) -> @gh.RawHttpResponse {
  let headers = head.headers
    .fields()
    .map(field => {
      // Valid UTF-8 is kept as text. For legacy opaque HTTP header octets,
      // Latin-1 maps each byte without replacement or data loss.
      let value = @utf8.decode(field.value.bytes) catch {
        _ => {
          let text = StringBuilder()
          for byte in field.value.bytes {
            text.write_char(byte.to_int().to_char().unwrap())
          }
          text.to_string()
        }
      }
      (field.name.value, value)
    })
  @gh.RawHttpResponse::new(status=head.status, headers~, body~)
}
