///|
/// Serialize a JSON value as compact JSON text (jq's `tojson`).
fn json_to_text(value : Json) -> String {
  let output = StringBuilder()
  fn write(value : Json) -> Unit {
    match value {
      Object(fields) => {
        output.write_char('{')
        for index, name in sorted_object_keys(fields) {
          if index > 0 {
            output.write_char(',')
          }
          output.write_string(Json(name).stringify())
          output.write_char(':')
          write(fields[name])
        }
        output.write_char('}')
      }
      Array(values) => {
        output.write_char('[')
        for index, value in values {
          if index > 0 {
            output.write_char(',')
          }
          write(value)
        }
        output.write_char(']')
      }
      _ => output.write_string(value.stringify())
    }
  }
  write(value)
  output.to_string()
}

///|
/// jq's `tostring`: strings are returned unchanged, everything else is
/// serialized as JSON text.
fn json_to_display_string(value : Json) -> String {
  match value {
    String(s) => s
    _ => json_to_text(value)
  }
}

///|
/// Evaluate ToJsonString
fn eval_to_json_string(input : Json) -> Iter[Json] {
  Iter::singleton(Json::string(json_to_text(input)))
}

///|
/// Evaluate FromJsonString
fn eval_from_json_string(input : Json) -> Iter[Json] raise InterpreterError {
  guard input is String(s) else {
    raise TypeMismatch("string", @ast_internal.json_type_name(input))
  }
  let parsed = @json.parse(s) catch {
    e => raise InvalidOperation("JSON parse error: \{e}")
  }
  Iter::singleton(parsed)
}
