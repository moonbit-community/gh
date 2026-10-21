///|
fn go_html(text : String) -> String {
  text
  .replace_all(old="&", new="&amp;")
  .replace_all(old="<", new="&lt;")
  .replace_all(old=">", new="&gt;")
  .replace_all(old="'", new="&#39;")
  .replace_all(old="\"", new="&#34;")
}

///|
fn go_urlquery(text : String) -> String {
  let output = StringBuilder()
  let hex = "0123456789ABCDEF"
  for byte in @utf8.encode(text) {
    let ch = byte.to_int().unsafe_to_char()
    if ch is ('a'..<='z' | 'A'..<='Z' | '0'..<='9' | '-' | '_' | '.' | '~') {
      output.write_char(ch)
    } else if ch == ' ' {
      output.write_char('+')
    } else {
      output.write_char('%')
      output.write_char(hex.get_char(byte.to_int() / 16).unwrap())
      output.write_char(hex.get_char(byte.to_int() % 16).unwrap())
    }
  }
  output.to_string()
}

///|
fn go_slice(values : Array[Value]) -> Value raise TemplateError {
  let value = arg_at(values, 0, "slice")
  let size = match value {
    List(items) => items.length()
    Str(text) => @utf8.encode(text).length()
    _ => raise ExecError("can't slice item of type " + go_type(value))
  }
  guard values.length() <= 4 else {
    raise ExecError(
      "too many slice indexes: " + (values.length() - 1).to_string(),
    )
  }
  let indexes = [0, size, size]
  for index in 1..<values.length() {
    guard values[index] is Int(number) else {
      raise ExecError(
        "cannot index slice/array with type " + go_type(values[index]),
      )
    }
    guard number >= 0L && number <= size.to_int64() else {
      raise ExecError("index out of range: " + number.to_string())
    }
    indexes[index - 1] = number.to_int()
  }
  guard indexes[0] <= indexes[1] && indexes[1] <= indexes[2] else {
    raise ExecError(
      "invalid slice index: " +
      indexes[0].to_string() +
      " > " +
      indexes[1].to_string(),
    )
  }
  match value {
    List(items) => List(items[indexes[0]:indexes[1]].to_owned())
    Str(text) => {
      guard values.length() <= 3 else {
        raise ExecError("cannot 3-index slice a string")
      }
      let bytes = @utf8.encode(text)[indexes[0]:indexes[1]].to_owned()
      Str(@utf8.decode_lossy(bytes))
    }
    _ => abort("validated slice type")
  }
}
