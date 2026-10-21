///|
/// Preserve log bytes while making C0/DEL controls visible. Prefix each line
/// exactly as gh does, with CRLF normalized by the scanner and no extra line
/// for a terminal newline.
pub fn render_run_log(job : String, step : String?, bytes : BytesView) -> Bytes {
  let sanitized = @buffer.Buffer()
  for byte in bytes {
    let code = byte.to_int()
    if code < 32 && !(code is (9 | 10 | 13)) {
      sanitized.write_byte(b'^')
      sanitized.write_byte((code + 64).to_byte())
    } else if code == 127 {
      sanitized.write_bytes(b"^?")
    } else {
      sanitized.write_byte(byte)
    }
  }
  let input = sanitized.to_bytes()
  let prefix = @utf8.encode(job + "\t" + step.unwrap_or("UNKNOWN STEP") + "\t")
  let output = @buffer.Buffer()
  let mut start = 0
  while start < input.length() {
    let mut end = start
    while end < input.length() && input[end] != b'\n' {
      end += 1
    }
    // gh uses bufio.Scanner's default 64 KiB token bound.
    if end - start >= 65536 {
      break
    }
    let content_end = if end > start && input[end - 1] == b'\r' {
      end - 1
    } else {
      end
    }
    output.write_bytes(prefix)
    output.write_bytes(input[start:content_end])
    output.write_byte(b'\n')
    start = end + 1
  }
  output.to_bytes()
}
