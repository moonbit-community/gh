///|
/// gh prints integral float64 scalars without decimals, other float64 scalars
/// with two decimals. Round the binary rational directly, with ties to even,
/// instead of multiplying the Double by 100 (which rounds a second time).
pub fn scalar_number(value : Double) -> String {
  fixed_number(value, if value.trunc() == value { 0 } else { 2 })
}

///|
pub fn fixed_number(value : Double, decimals : Int32) -> String {
  if value.is_nan() {
    return "NaN"
  }
  if value.is_inf() {
    return if value < 0 { "-Inf" } else { "+Inf" }
  }
  let bits = value.reinterpret_as_uint64()
  let negative = bits >> 63 != 0UL
  let exponent = ((bits >> 52) & 0x7ffUL).to_int()
  let fraction = bits & 0xfffffffffffffUL
  let significand = if exponent == 0 {
    fraction
  } else {
    fraction | 0x10000000000000UL
  }
  let power = if exponent == 0 { -1074 } else { exponent - 1075 }
  let mut scale : @bigint.BigInt = 1N
  for _ in 0..<decimals {
    scale *= 10N
  }
  let numerator = @bigint.BigInt::from_uint64(significand) * scale
  let rounded = if power >= 0 {
    numerator << power
  } else {
    let denominator = 1N << -power
    let quotient = numerator / denominator
    let remainder = numerator % denominator
    if remainder * 2N > denominator ||
      (remainder * 2N == denominator && quotient % 2N == 1N) {
      quotient + 1N
    } else {
      quotient
    }
  }
  let digits = rounded.to_string()
  let magnitude = if decimals == 0 {
    digits
  } else if digits.length() <= decimals {
    "0." + "0".repeat(decimals - digits.length()) + digits
  } else {
    digits[:digits.length() - decimals].to_owned() +
    "." +
    digits[digits.length() - decimals:].to_owned()
  }
  (if negative { "-" } else { "" }) + magnitude
}
