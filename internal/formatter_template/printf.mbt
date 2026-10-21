///|
fn go_type(value : Value) -> String {
  match value {
    Null => "<nil>"
    Str(_) => "string"
    Float(_) => "float64"
    Int(_) => "int"
    Bool(_) => "bool"
    List(_) => "[]interface {}"
    Dict(_) => "map[string]interface {}"
  }
}

///|
fn printf_value(value : Value) -> String {
  match value {
    Null => "<nil>"
    _ => to_output(value)
  }
}

///|
fn printf_mismatch(verb : Char, value : Value) -> String {
  "%!" +
  verb.to_string() +
  "(" +
  go_type(value) +
  "=" +
  printf_value(value) +
  ")"
}

///|
fn printf_field(
  value : Value,
  verb : Char,
  precision : Int32?,
  alternate : Bool,
) -> String {
  match (value, verb) {
    (_, 'v') => printf_value(value)
    (_, 'T') => go_type(value)
    (Str(text), 's' | 'q') => {
      let text = match precision {
        Some(count) => {
          let result = StringBuilder()
          for ch in text.iter().take(count.max(0)) {
            result.write_char(ch)
          }
          result.to_string()
        }
        None => text
      }
      if verb == 'q' {
        Json(text).stringify()
      } else {
        text
      }
    }
    (Bool(value), 't') => if value { "true" } else { "false" }
    (Float(value), 'f' | 'F') =>
      @formatter_common.fixed_number(value, precision.unwrap_or(6).min(10000))
    (Int(value), 'd' | 'b' | 'o' | 'x' | 'X') => {
      let radix = match verb {
        'd' => 10
        'b' => 2
        'o' => 8
        _ => 16
      }
      let digits = value.to_string(radix~)
      let digits = if verb == 'X' { digits.to_upper() } else { digits }
      let digits = "0".repeat((precision.unwrap_or(0) - digits.length()).max(0)) +
        digits
      let prefix = if !alternate {
        ""
      } else {
        match verb {
          'x' => "0x"
          'X' => "0X"
          'o' => "0"
          'b' => "0b"
          _ => ""
        }
      }
      prefix + digits
    }
    (Int(value), 'c') =>
      if value >= 0L && value <= 0x10ffffL {
        value.to_int().unsafe_to_char().to_string()
      } else {
        "\ufffd"
      }
    _ => printf_mismatch(verb, value)
  }
}

///|
fn go_printf(format : String, args : Array[Value], start : Int32) -> String {
  let output = StringBuilder()
  let mut cursor = 0
  let mut next_arg = start
  let mut reordered = false
  while cursor < format.length() {
    let ch = format.get_char(cursor).unwrap()
    cursor += if ch.to_int() > 0xffff { 2 } else { 1 }
    if ch != '%' {
      output.write_char(ch)
      continue
    }
    if cursor < format.length() && format[cursor] == '%' {
      output.write_char('%')
      cursor += 1
      continue
    }
    let mut left = false
    let mut zero = false
    let mut plus = false
    let mut space = false
    let mut alternate = false
    while cursor < format.length() {
      match format[cursor] {
        '-' => left = true
        '0' => zero = true
        '+' => plus = true
        ' ' => space = true
        '#' => alternate = true
        _ => break
      }
      cursor += 1
    }
    let (index, after_index) = printf_index(format, cursor)
    if index is Some(index) {
      next_arg = start + index - 1
      cursor = after_index
      reordered = true
    }
    let mut width = 0
    while cursor < format.length() && is_digit(format[cursor]) {
      width = (width * 10 + format[cursor].to_int() - 48).min(10000)
      cursor += 1
    }
    if cursor < format.length() && format[cursor] == '*' {
      cursor += 1
      match args.get(next_arg) {
        Some(Int(value)) if value >= -10000L && value <= 10000L => {
          width = value.abs().to_int()
          if value < 0 {
            left = true
            zero = false
          }
        }
        _ => output.write_string("%!(BADWIDTH)")
      }
      next_arg += 1
    }
    let mut precision : Int32? = None
    if cursor < format.length() && format[cursor] == '.' {
      cursor += 1
      let (index, after_index) = printf_index(format, cursor)
      if index is Some(index) {
        next_arg = start + index - 1
        cursor = after_index
        reordered = true
      }
      let mut count = 0
      while cursor < format.length() && is_digit(format[cursor]) {
        count = (count * 10 + format[cursor].to_int() - 48).min(10000)
        cursor += 1
      }
      if cursor < format.length() && format[cursor] == '*' {
        cursor += 1
        match args.get(next_arg) {
          Some(Int(value)) if value >= 0L && value <= 10000L =>
            precision = Some(value.to_int())
          _ => output.write_string("%!(BADPREC)")
        }
        next_arg += 1
      } else {
        precision = Some(count)
      }
    }
    let (index, after_index) = printf_index(format, cursor)
    if index is Some(index) {
      next_arg = start + index - 1
      cursor = after_index
      reordered = true
    }
    guard cursor < format.length() else {
      output.write_string("%!(NOVERB)")
      break
    }
    let verb = format.get_char(cursor).unwrap()
    cursor += if verb.to_int() > 0xffff { 2 } else { 1 }
    guard args.get(next_arg) is Some(value) else {
      output.write_string("%!" + verb.to_string() + "(MISSING)")
      continue
    }
    next_arg += 1
    let mut text = printf_field(value, verb, precision, alternate)
    if (plus || space) &&
      value is (Int(_) | Float(_)) &&
      !text.has_prefix("-") &&
      !text.has_prefix("%!") {
      text = (if plus { "+" } else { " " }) + text
    }
    let pad = (width - text.char_length()).max(0)
    if left {
      output.write_string(text + " ".repeat(pad))
    } else if zero && pad > 0 {
      if text.has_prefix("-") || text.has_prefix("+") || text.has_prefix(" ") {
        output.write_string(
          text[:1].to_owned() + "0".repeat(pad) + text[1:].to_owned(),
        )
      } else {
        output.write_string("0".repeat(pad) + text)
      }
    } else {
      output.write_string(" ".repeat(pad) + text)
    }
  }
  if !reordered && next_arg < args.length() {
    let extra = args[next_arg:].map(value => {
      go_type(value) + "=" + printf_value(value)
    })
    output.write_string("%!(EXTRA " + extra.join(", ") + ")")
  }
  output.to_string()
}

///|
fn printf_index(format : String, cursor : Int32) -> (Int32?, Int32) {
  if cursor >= format.length() || format[cursor] != '[' {
    return (None, cursor)
  }
  let mut end = cursor + 1
  let mut index = 0
  while end < format.length() && is_digit(format[end]) {
    index = (index * 10 + format[end].to_int() - 48).min(100000)
    end += 1
  }
  if end > cursor + 1 &&
    end < format.length() &&
    format[end] == ']' &&
    index > 0 {
    (Some(index), end + 1)
  } else {
    (None, cursor)
  }
}
