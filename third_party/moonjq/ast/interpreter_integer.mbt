///|
/// Integer lexemes come from jq literals, not from gh's float64 JSON input.
/// Keep the exact spelling in Json's representation slot so integer arithmetic
/// does not silently round at 2^53. Decimal/exponent operands remain float64.
fn integer_value(value : Json) -> @bigint.BigInt? {
  guard value is Number(_, repr=Some(text)) else { return None }
  let digits : StringView = if text.has_prefix("-") { text[1:] } else { text }
  if digits.is_empty() || !digits.iter().all(c => c >= '0' && c <= '9') {
    return None
  }
  Some(@bigint.BigInt::from_string(text))
}

///|
fn integer_json(value : @bigint.BigInt) -> Json {
  let text = value.to_string()
  Json::number(@string.parse_double(text) catch { _ => 0.0 }, repr=text)
}
