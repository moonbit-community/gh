///|
/// Evaluate Explode
fn eval_explode(input : Json) -> Iter[Json] raise InterpreterError {
  guard input is String(s) else {
    raise TypeMismatch("string", @ast_internal.json_type_name(input))
  }
  let results = s
    .iter()
    .map(fn(char) { Json::number(char.to_int().to_double()) })
    .to_array()
  Iter::singleton(Json::array(results))
}

///|
/// Evaluate Implode
fn eval_implode(input : Json) -> Iter[Json] raise InterpreterError {
  guard input is Array(arr) else {
    raise TypeMismatch("array", @ast_internal.json_type_name(input))
  }
  let chars = arr.filter_map(fn(elem) {
    match elem {
      Number(n, ..) => Int32::to_char(n.to_int())
      _ => None
    }
  })
  let result = String::from_array(chars)
  Iter::singleton(Json::string(result))
}

///|
/// Evaluate Scan
fn eval_scan(
  pattern : String,
  input : Json,
) -> Iter[Json] raise InterpreterError {
  eval_regex_call("scan", [Literal(String(pattern))], input, Env::new())
}
