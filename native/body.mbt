///|
// Limit input before UTF-8 decoding. Typed text operations additionally apply
// MoonHub's 20,000-unit policy; generic JSON API input uses this 80,000-byte cap.
async fn read_body(reader : &@io.Reader) -> String {
  let buffer = @buffer.Buffer(size_hint=4096)
  while true {
    let remaining = 80001 - buffer.length()
    let chunk = reader.read_some(
      max_len=if remaining < 4096 { remaining } else { 4096 },
    )
    match chunk {
      None => break
      Some(bytes) => {
        buffer.write_bytes(bytes)
        if buffer.length() > 80000 {
          fail("body input limit exceeded")
        }
      }
    }
  }
  @utf8.decode(buffer.to_bytes())
}

///|
async fn read_body_file(path : String) -> String {
  if @fs.kind(path) != @fs.Regular {
    fail("body input must be a regular file")
  }
  let file = @fs.open(path, mode=ReadOnly)
  defer file.close()
  if file.kind() != @fs.Regular || file.size() > 80000L {
    fail("body input must be a bounded regular file")
  }
  read_body(file)
}

///|
/// Explicit file/stdin body sources only. Literal arguments stay in the pure
/// CLI facade; no filesystem paths or decoding details enter diagnostics.
async fn load_body(input : @cli.BodyInput?) -> Result[String?, @gh.ApiError] {
  try {
    match input {
      None | Some(@cli.Literal(_)) => Ok(None)
      Some(@cli.File(path)) =>
        Ok(Some(@async.with_timeout(30000, () => read_body_file(path))))
      Some(@cli.Stdin) =>
        Ok(Some(@async.with_timeout(30000, () => read_body(@stdio.stdin))))
    }
  } catch {
    err if @async.is_cancellation_error(err) => raise err
    _ =>
      Err(
        @gh.InvalidRequest(
          message="cannot read body input as bounded UTF-8 text",
        ),
      )
  }
}
