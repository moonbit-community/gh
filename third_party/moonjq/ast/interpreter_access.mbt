///|
fn normalize_index(idx : Int32, len : Int32) -> Int32 {
  if idx < 0 {
    len + idx
  } else {
    idx
  }
}

///|
fn clamp_index(value : Int32, len : Int32) -> Int32 {
  if value < 0 {
    0
  } else if value > len {
    len
  } else {
    value
  }
}

///|
fn index_in_bounds(idx : Int32, len : Int32) -> Bool {
  idx >= 0 && idx < len
}

///|
fn array_index_or_null(arr : Array[Json], len : Int32, idx : Int32) -> Json {
  let actual_idx = normalize_index(idx, len)
  if index_in_bounds(actual_idx, len) {
    arr[actual_idx]
  } else {
    null
  }
}

///|
/// Evaluate field access against input JSON
fn eval_key_access(
  key : String,
  input : Json,
) -> Iter[Json] raise InterpreterError {
  match input {
    Object(obj) => Iter::singleton(obj.get(key).unwrap_or(null))
    Null => Iter::singleton(null)
    _ => raise EvalError("expected an object but got: " + gh_describe(input))
  }
}

///|
/// Evaluate array indexing and iteration
fn eval_index_access(
  indices : Array[Int32],
  input : Json,
) -> Iter[Json] raise InterpreterError {
  match indices {
    [] =>
      // Empty index means iterate over array/object values
      match input {
        Array(arr) => arr.iter()
        Object(obj) => obj.values()
        _ => raise EvalError("cannot iterate over: " + gh_describe(input))
      }
    _ =>
      // Multiple indices produce multiple results
      match input {
        Array(arr) => {
          let len = arr.length()
          indices.iter().map(fn(idx) { array_index_or_null(arr, len, idx) })
        }
        Null => Iter::repeat(null).take(indices.length())
        _ => raise EvalError("expected an array but got: " + gh_describe(input))
      }
  }
}

///|
fn gh_describe(input : Json) -> String {
  match input {
    Null => "null"
    _ => @ast_internal.json_type_name(input) + " (" + input.stringify() + ")"
  }
}

///|
fn dynamic_index(input : Json, key : Json) -> Json raise InterpreterError {
  match key {
    String(name) => eval_key_access(name, input).next().unwrap_or(null)
    Number(number, ..) =>
      eval_index_access([number.to_int()], input).next().unwrap_or(null)
    Array(needle) => {
      guard input is Array(haystack) else {
        raise EvalError("expected an array but got: " + gh_describe(input))
      }
      let positions : Array[Json] = []
      if !needle.is_empty() {
        for i in 0..<(haystack.length() - needle.length() + 1) {
          if compare_array_view(haystack[i:i + needle.length()], needle) == 0 {
            positions.push(integer_json(@bigint.BigInt::from_int(i)))
          }
        }
      }
      Json(positions)
    }
    Object(fields) => {
      guard fields.contains("start") && fields.contains("end") else {
        raise EvalError(
          "expected \"start\" and \"end\" for slicing but got: " +
          gh_describe(key),
        )
      }
      fn endpoint(value : Json) -> Int32? raise InterpreterError {
        match value {
          Null => None
          Number(number, ..) => Some(number.to_int())
          _ =>
            raise EvalError("expected a number but got: " + gh_describe(value))
        }
      }
      eval_slice_access(
        endpoint(fields["start"]),
        endpoint(fields["end"]),
        input,
      )
      .next()
      .unwrap_or(null)
    }
    _ =>
      raise EvalError(
        "expected a string for object key but got: " + gh_describe(key),
      )
  }
}

///|
/// Evaluate array slicing
fn eval_slice_access(start : Int32?, end : Int32?, input : Json) -> Iter[Json] {
  if input is String(value) {
    let chars = value.iter().collect()
    let len = chars.length()
    let from = clamp_index(
      start.map(n => normalize_index(n, len)).unwrap_or(0),
      len,
    )
    let until = clamp_index(
      end.map(n => normalize_index(n, len)).unwrap_or(len),
      len,
    )
    let output = StringBuilder()
    for i in from..<until {
      output.write_char(chars[i])
    }
    return Iter::singleton(Json::string(output.to_string()))
  }
  guard input is Array(arr) else { return Iter::singleton(null) }
  let len = arr.length()
  let s = start.map(fn(n) { normalize_index(n, len) }).unwrap_or(0)
  let e = end.map(fn(n) { normalize_index(n, len) }).unwrap_or(len)
  let s_clamped = clamp_index(s, len)
  let e_clamped = clamp_index(e, len)
  let sliced = if s_clamped >= e_clamped {
    []
  } else {
    arr[s_clamped:e_clamped].to_owned()
  }
  Iter::singleton(Json::array(sliced))
}

///|
/// Evaluate optional expression, suppressing errors
fn eval_optional(
  inner : Expr,
  input : Json,
  env : Env,
) -> Iter[Json] raise InterpreterError {
  collect_stream(Optional(inner), input, env)
}
