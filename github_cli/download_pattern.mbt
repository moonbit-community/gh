///|
priv enum FilenamePart {
  Literal(Char)
  Any
  Star
  Class(Array[(Char, Char)], Bool)
}

///|
/// Match gh's filepath-style name patterns. Unlike the former release
/// wildcard shortcut, '?' and bracket ranges operate on Unicode characters,
/// stars cannot cross '/', and malformed patterns do not match.
pub fn download_name_matches(name : String, pattern : String) -> Bool {
  let source = pattern.to_array()
  let parts : Array[FilenamePart] = []
  let mut i = 0
  while i < source.length() {
    let ch = source[i]
    i += 1
    match ch {
      '*' => parts.push(Star)
      '?' => parts.push(Any)
      '\\' => {
        guard i < source.length() else { return false }
        parts.push(Literal(source[i]))
        i += 1
      }
      '[' => {
        let negate = i < source.length() && source[i] == '^'
        if negate {
          i += 1
        }
        let ranges : Array[(Char, Char)] = []
        while i < source.length() && source[i] != ']' {
          let mut low = source[i]
          i += 1
          if low == '\\' {
            guard i < source.length() else { return false }
            low = source[i]
            i += 1
          }
          guard low != '-' else { return false }
          let mut high = low
          if i < source.length() && source[i] == '-' {
            i += 1
            guard i < source.length() && source[i] != ']' else { return false }
            high = source[i]
            i += 1
            if high == '\\' {
              guard i < source.length() else { return false }
              high = source[i]
              i += 1
            }
          }
          ranges.push((low, high))
        }
        guard i < source.length() && !ranges.is_empty() else { return false }
        i += 1
        parts.push(Class(ranges, negate))
      }
      _ => parts.push(Literal(ch))
    }
  }
  let input = name.to_array()
  let mut matches = Array::make(input.length() + 1, false)
  matches[0] = true
  for part in parts {
    let next = Array::make(input.length() + 1, false)
    match part {
      Star => {
        next[0] = matches[0]
        for j in 1..<=input.length() {
          next[j] = matches[j] || (next[j - 1] && input[j - 1] != '/')
        }
      }
      _ =>
        for j in 1..<=input.length() {
          let ch = input[j - 1]
          next[j] = matches[j - 1] &&
            (match part {
              Literal(expected) => ch == expected
              Any => ch != '/'
              Class(ranges, negate) =>
                ch != '/' &&
                ranges.any(pair => ch >= pair.0 && ch <= pair.1) != negate
              Star => false
            })
        }
    }
    matches = next
  }
  matches[input.length()]
}
