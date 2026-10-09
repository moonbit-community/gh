///|
/// An opaque, strong HTTP entity tag. Use the exact tag returned by the server;
/// resource versions are not substitutes for the server's concurrency token.
pub struct EntityTag {
  priv raw : String
}

///|
/// Accept one bounded ASCII strong tag, including the surrounding quotes.
pub fn EntityTag::parse(value : String) -> Result[EntityTag, @gh.ApiError] {
  let length = value.length()
  guard length >= 2 &&
    length <= 256 &&
    value[0] == '"' &&
    value[length - 1] == '"' else {
    return Err(@gh.InvalidRequest(message="expected one strong quoted ETag"))
  }
  for index in 1..<(length - 1) {
    let character = value[index]
    guard character >= 0x21 && character <= 0x7e && character != '"' else {
      return Err(@gh.InvalidRequest(message="expected one strong quoted ETag"))
    }
  }
  Ok({ raw: value, })
}

///|
pub fn EntityTag::value(self : EntityTag) -> String {
  self.raw
}

///|
/// Treat repeated fields as ambiguous even if their values happen to match.
/// Native HTTP combines repeated headers, which the quoted-tag parser rejects.
fn response_etag(response : @gh.Response) -> Result[EntityTag?, @gh.ApiError] {
  let mut result : EntityTag? = None
  for (name, value) in response.headers {
    if name.equal_ignore_ascii_case("etag") {
      if result is Some(_) {
        return Err(@gh.Decode(message="invalid or repeated response ETag"))
      }
      match EntityTag::parse(value) {
        Ok(tag) => result = Some(tag)
        Err(_) =>
          return Err(@gh.Decode(message="invalid or repeated response ETag"))
      }
    }
  }
  Ok(result)
}
