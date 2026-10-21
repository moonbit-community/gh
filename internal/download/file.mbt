///|
/// Write into an exclusively created sibling and publish only after framing,
/// callbacks and file synchronization all succeed. Rename never follows a
/// destination symlink, and replace=false is checked atomically by the OS.
pub async fn to_file(
  target : String,
  receive : async (@gh.RawResponseSink) -> @gh.RawDownloadResult,
  replace~ : Bool = false,
  permission~ : Int32 = 0o600,
) -> @gh.RawDownloadResult {
  guard !target.is_empty() && !target.contains_char('\u0000') else {
    fail("invalid download destination")
  }
  let (directory, name) = match target.rev_split_once("/") {
    Some((parent, name)) =>
      (if parent.is_empty() { "/" } else { parent.to_owned() }, name.to_owned())
    None => (".", target)
  }
  guard !name.is_empty() &&
    name != "." &&
    name != ".." &&
    !name.contains_char('\\') &&
    !name.contains_char(':') else {
    fail("invalid download filename")
  }
  let parent = @fs.realpath(directory)
  guard @fs.kind(parent) == @fs.Directory else {
    fail("download parent is not a directory")
  }
  let destination = parent + "/" + name
  if !replace && @fs.exists(destination) {
    fail("download destination already exists")
  }
  let temporary = parent + "/.gh-download-" + temporary_suffix()
  let file = @fs.open(
    temporary,
    mode=WriteOnly,
    create_mode=CreateNew,
    permission~,
  )
  let mut committed = false
  defer {
    file.close()
    if !committed {
      @fs.remove(temporary)
    }
  }
  let mut accepted = false
  let mut observed : @gh.RawResponseHead? = None
  let mut written = 0L
  let result = receive(
    @gh.RawResponseSink::new(
      headers=head => {
        guard observed is None else { fail("multiple final response headers") }
        observed = Some(head)
        accepted = head.status() >= 200 && head.status() < 300
        accepted
      },
      chunk=bytes => {
        guard accepted else {
          fail("download body preceded successful headers")
        }
        file.write(bytes)
        written += bytes.length().to_int64()
      },
    ),
  )
  guard observed is Some(head) &&
    head.status() == result.head().status() &&
    head.headers() == result.head().headers() &&
    written == result.bytes_received() else {
    fail("download receipt does not match received content")
  }
  if !accepted || !result.complete() {
    return result
  }
  file.sync()
  file.close()
  @fs.rename(temporary, destination, replace~)
  committed = true
  result
}

///|
fn temporary_suffix() -> String raise {
  let random = @env.rand(16).unwrap_or_else(() => {
    fail("cannot generate download temporary name")
  })
  let suffix = StringBuilder()
  for byte in random {
    let value = byte.to_int()
    suffix.write_char("0123456789abcdef".get_char(value >> 4).unwrap())
    suffix.write_char("0123456789abcdef".get_char(value & 15).unwrap())
  }
  suffix.to_string()
}
