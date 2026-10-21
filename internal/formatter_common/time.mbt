///|
/// Shared RFC3339 decoding for templates and Actions presentation. Retains
/// nanoseconds and the original numeric zone rather than truncating to seconds.
pub fn parse_rfc3339(
  source : String,
) -> Result[(@time.PlainDateTime, Int32), String] {
  try {
    guard source.length() >= 20 && source[10] == 'T' else {
      return Err("invalid RFC3339 timestamp")
    }
    let (date, offset) = if source.has_suffix("Z") {
      (source[:source.length() - 1].to_owned(), 0)
    } else {
      let start = source.length() - 6
      guard source[start] is ('+' | '-') && source[start + 3] == ':' else {
        return Err("invalid RFC3339 timezone")
      }
      let hours = @string.parse_int(source[start + 1:start + 3])
      let minutes = @string.parse_int(source[start + 4:])
      guard hours >= 0 && hours <= 23 && minutes >= 0 && minutes <= 59 else {
        return Err("invalid RFC3339 timezone")
      }
      let sign = if source[start] == '-' { -1 } else { 1 }
      (source[:start].to_owned(), sign * (hours * 3600 + minutes * 60))
    }
    let parsed : @time.PlainDateTime = @string.from_str(date)
    Ok((parsed, offset))
  } catch {
    _ => Err("invalid RFC3339 timestamp")
  }
}
