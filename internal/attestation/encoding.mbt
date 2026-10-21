///|
pub suberror VerificationError {
  Invalid(String)
}

///|
fn required(value : Json, key : String) -> Json raise VerificationError {
  match value {
    Object(fields) =>
      fields
      .get(key)
      .unwrap_or_else(() => raise Invalid("missing verification metadata"))
    _ => raise Invalid("expected verification metadata object")
  }
}

///|
fn required_string(
  value : Json,
  key : String,
) -> String raise VerificationError {
  match required(value, key) {
    String(value) => value
    _ => raise Invalid("expected verification metadata string")
  }
}

///|
fn required_integer(
  value : Json,
  key : String,
) -> Int64 raise VerificationError {
  match required(value, key) {
    Number(number, ..) if number >= 0 &&
      number < 9007199254740992.0 &&
      number == number.to_int64().to_double() => number.to_int64()
    _ => raise Invalid("expected nonnegative verification metadata integer")
  }
}

///|
fn decode_json(bytes : Bytes) -> Json raise VerificationError {
  guard bytes.length() <= 10485760 else {
    raise Invalid("verification metadata exceeds size limit")
  }
  @bounded_json.parse(@utf8.decode(bytes)) catch {
    _ => raise Invalid("invalid verification JSON")
  }
}

///|
fn lexicographic(a : String, b : String) -> Int32 {
  let x = a.iter()
  let y = b.iter()
  while true {
    match (x.next(), y.next()) {
      (None, None) => return 0
      (None, _) => return -1
      (_, None) => return 1
      (Some(x), Some(y)) => if x != y { return x.compare(y) }
    }
  }
  0
}

///|
/// TUF uses OLPC canonical JSON, whose strings escape only quote and
/// backslash. JSON.stringify would incorrectly escape PEM newlines here.
/// Reference: go-securesystemslib/cjson/canonicaljson.go.
fn canonical_json(
  value : Json,
  depth~ : Int32 = 0,
) -> String raise VerificationError {
  guard depth < 64 else { raise Invalid("verification metadata nesting limit") }
  match value {
    Null => "null"
    True => "true"
    False => "false"
    String(value) =>
      "\"" +
      value.replace_all(old="\\", new="\\\\").replace_all(old="\"", new="\\\"") +
      "\""
    Number(number, repr~) =>
      if repr is Some(text) {
        ignore(@string.parse_int64(text)) catch {
          _ => raise Invalid("noninteger canonical JSON number")
        }
        text
      } else {
        guard number > -9007199254740992.0 &&
          number < 9007199254740992.0 &&
          number == number.to_int64().to_double() else {
          raise Invalid("noninteger canonical JSON number")
        }
        number.to_int64().to_string()
      }
    Array(values) =>
      "[" +
      values.map(value => canonical_json(value, depth=depth + 1)).join(",") +
      "]"
    Object(fields) => {
      let keys = fields.keys().collect()
      keys.sort_by(lexicographic)
      "{" +
      keys
      .map(key => {
        canonical_json(Json(key), depth=depth + 1) +
        ":" +
        canonical_json(fields[key], depth=depth + 1)
      })
      .join(",") +
      "}"
    }
  }
}

///|
fn decode_hex(value : String) -> Bytes raise VerificationError {
  guard value.length() % 2 == 0 else { raise Invalid("invalid hex encoding") }
  let output = @buffer.Buffer()
  let mut high = -1
  for ch in value {
    let digit = match ch {
      '0'..<='9' => ch.to_int() - 48
      'a'..<='f' => ch.to_int() - 87
      'A'..<='F' => ch.to_int() - 55
      _ => raise Invalid("invalid hex encoding")
    }
    if high < 0 {
      high = digit
    } else {
      output.write_byte((high * 16 + digit).to_byte())
      high = -1
    }
  }
  output.to_bytes()
}

///|
fn timestamp(value : String) -> Int64 raise VerificationError {
  timestamp_parts(value).0
}

///|
fn timestamp_parts(value : String) -> (Int64, Int32) raise VerificationError {
  guard value.strip_suffix("Z") is Some(date) else {
    raise Invalid("expected UTC verification time")
  }
  let time : @time.PlainDateTime = @string.from_str(date) catch {
    _ => raise Invalid("invalid verification time")
  }
  (time.to_unix_second(), time.nanosecond())
}
