///|
/// Pretty-print validated wire JSON without rebuilding its objects or numbers.
/// Raw API output preserves wire key order, unlike jq's sorted object output.
pub fn pretty_wire_json(text : String) -> String {
  let chars = text.iter().collect()
  let tokens : Array[String] = []
  let mut cursor = 0
  while cursor < chars.length() {
    if chars[cursor] is (' ' | '\n' | '\r' | '\t') {
      cursor += 1
      continue
    }
    let token = StringBuilder()
    if chars[cursor] == '"' {
      token.write_char('"')
      cursor += 1
      while cursor < chars.length() {
        let ch = chars[cursor]
        token.write_char(ch)
        cursor += 1
        if ch == '\\' && cursor < chars.length() {
          token.write_char(chars[cursor])
          cursor += 1
        } else if ch == '"' {
          break
        }
      }
    } else if chars[cursor] is ('{' | '}' | '[' | ']' | ':' | ',') {
      token.write_char(chars[cursor])
      cursor += 1
    } else {
      while cursor < chars.length() &&
            !(chars[cursor]
            is (' ' | '\n' | '\r' | '\t' | '{' | '}' | '[' | ']' | ':' | ',')) {
        token.write_char(chars[cursor])
        cursor += 1
      }
    }
    tokens.push(token.to_string())
  }
  let output = StringBuilder()
  let mut depth = 0
  fn newline() {
    output.write_char('\n')
    output.write_string(" ".repeat(depth.max(0) * 2))
  }
  for index, token in tokens {
    match token {
      "{" | "[" => {
        output.write_string(token)
        depth += 1
        if !(tokens.get(index + 1) is Some("}" | "]")) {
          newline()
        }
      }
      "}" | "]" => {
        depth -= 1
        if !(tokens.get(index - 1) is Some("{" | "[")) {
          newline()
        }
        output.write_string(token)
      }
      "," => {
        output.write_char(',')
        newline()
      }
      ":" => output.write_string(": ")
      _ => output.write_string(token)
    }
  }
  output.write_char('\n')
  output.to_string()
}

///|
/// Replace dangerous decoded control characters within JSON strings while
/// retaining the server's whitespace, key order and numeric representations.
pub fn sanitize_wire_json(text : String) -> String {
  let chars = text.iter().collect()
  let output = StringBuilder()
  let mut cursor = 0
  while cursor < chars.length() {
    let ch = chars[cursor]
    if ch == '\\' && cursor + 1 < chars.length() {
      let next = chars[cursor + 1]
      let mut code = -1
      let mut consumed = 2
      if next == 'u' && cursor + 5 < chars.length() {
        code = 0
        for index in (cursor + 2)..<(cursor + 6) {
          let digit = match chars[index] {
            '0'..<='9' as ch => ch.to_int() - 48
            'a'..<='f' as ch => ch.to_int() - 87
            'A'..<='F' as ch => ch.to_int() - 55
            _ => 0
          }
          code = code * 16 + digit
        }
        consumed = 6
      } else if next == 'b' {
        code = 8
      } else if next == 'f' {
        code = 12
      }
      if (code >= 0 && code < 32 && !(code is (9 | 10 | 13))) || code == 127 {
        output.write_char('^')
        output.write_char(
          if code == 127 {
            '?'
          } else {
            (code + 64).unsafe_to_char()
          },
        )
      } else {
        for index in cursor..<(cursor + consumed) {
          output.write_char(chars[index])
        }
      }
      cursor += consumed
    } else {
      output.write_char(ch)
      cursor += 1
    }
  }
  output.to_string()
}
