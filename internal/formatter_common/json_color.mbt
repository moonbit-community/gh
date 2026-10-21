///|
/// Color already-serialized JSON, preserving its whitespace, ordering and
/// numeric spelling. String tokens are scanned with escapes before deciding
/// whether they are object keys.
pub fn color_json(text : String, punctuation~ : String = "1;38") -> String {
  let chars = text.iter().collect()
  let output = StringBuilder()
  let mut cursor = 0
  while cursor < chars.length() {
    let start = cursor
    let code = match chars[cursor] {
      '"' => {
        cursor += 1
        while cursor < chars.length() {
          if chars[cursor] == '\\' {
            cursor += 2
          } else if chars[cursor] == '"' {
            cursor += 1
            break
          } else {
            cursor += 1
          }
        }
        let mut lookahead = cursor
        while lookahead < chars.length() &&
              chars[lookahead] is (' ' | '\n' | '\r' | '\t') {
          lookahead += 1
        }
        if chars.get(lookahead) == Some(':') {
          "1;34"
        } else {
          "32"
        }
      }
      '{' | '}' | '[' | ']' | ':' | ',' => {
        cursor += 1
        punctuation
      }
      't' => {
        cursor += 4
        "33"
      }
      'f' => {
        cursor += 5
        "33"
      }
      'n' => {
        cursor += 4
        "36"
      }
      _ => {
        cursor += 1
        ""
      }
    }
    if !code.is_empty() {
      output.write_string("\u001b[" + code + "m")
    }
    for index in start..<cursor.min(chars.length()) {
      output.write_char(chars[index])
    }
    if !code.is_empty() {
      output.write_string("\u001b[m")
    }
  }
  output.to_string()
}
