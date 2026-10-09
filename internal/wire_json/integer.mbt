///|
/// Validate a nonnegative integer from an already parsed JSON number without
/// trusting its rounded Double alone. Decimal/exponent spellings remain valid
/// when their exact value is integral. Bounds stay in JSON's safe integer range.
/// The upstream parser owns JSON syntax; this is a bounded wire-value check.
pub fn integer(value : Json, minimum~ : Int64, maximum~ : Int64) -> Int64? {
  guard minimum >= 0 &&
    maximum <= 9007199254740991L &&
    minimum <= maximum &&
    value is Number(number, repr~) &&
    number >= minimum.to_double() &&
    number <= maximum.to_double() else {
    return None
  }
  let integer = number.to_int64()
  guard integer.to_double() == number else { return None }
  guard repr is Some(source) else { return Some(integer) }
  let source = source.to_lower()
  let (mantissa, exponent) = match source.split_once("e") {
    Some((mantissa, exponent)) => (mantissa.to_owned(), Some(exponent))
    None => (source, None)
  }
  let negative = mantissa.has_prefix("-")
  let mantissa = mantissa
    .strip_prefix("-")
    .map_or(mantissa, part => part.to_owned())
  let (whole, fraction) = match mantissa.split_once(".") {
    Some((whole, fraction)) => (whole.to_owned(), fraction.to_owned())
    None => (mantissa, "")
  }
  let digits = whole + fraction
  guard !whole.is_empty() && digits.iter().all(ch => ch is ('0'..='9')) else {
    return None
  }
  let digits = digits.trim_start(chars="0")
  // Zero remains zero at any exponent, including one too large for Int64.
  if digits.is_empty() {
    return if integer == 0 { Some(0L) } else { None }
  }
  guard !negative else { return None }
  let exponent = match exponent {
    None => 0L
    Some(text) => @string.parse_int64(text) catch { _ => return None }
  }
  // A nonzero coefficient outside these bounds cannot fit an integral result.
  guard exponent >= -source.length().to_int64() &&
    exponent <= source.length().to_int64() + 16 else {
    return None
  }
  let significant = digits.trim_end(chars="0")
  let zeros = exponent -
    fraction.length().to_int64() +
    digits.length().to_int64() -
    significant.length().to_int64()
  let expected = integer.to_string()
  guard zeros >= 0 &&
    significant.length().to_int64() + zeros == expected.length().to_int64() else {
    return None
  }
  let normalized = StringBuilder()
  normalized.write_string(significant.to_owned())
  for _ in 0..<zeros.to_int() {
    normalized.write_char('0')
  }
  if normalized.to_string() == expected {
    Some(integer)
  } else {
    None
  }
}
