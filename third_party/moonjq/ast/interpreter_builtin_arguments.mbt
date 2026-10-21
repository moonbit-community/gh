///|
fn argument_builtin_arity(name : String, count : Int32) -> Bool {
  match name {
    "split" => count is (1 | 2)
    "join"
    | "startswith"
    | "endswith"
    | "ltrimstr"
    | "rtrimstr"
    | "contains"
    | "inside"
    | "has"
    | "in" => count == 1
    "scalars"
    | "arrays"
    | "objects"
    | "booleans"
    | "numbers"
    | "strings"
    | "nulls"
    | "iterables" => count == 0
    _ => false
  }
}

///|
fn contains_value(container : Json, value : Json) -> Bool {
  match (container, value) {
    (String(text), String(part)) => text.contains(part)
    (Array(values), Array(parts)) =>
      parts.all(part => values.any(value => contains_value(value, part)))
    (Object(fields), Object(parts)) =>
      parts
      .iter()
      .all(pair => {
        fields.get(pair.0).map_or(false, value => contains_value(value, pair.1))
      })
    _ => compare_json(container, value) == 0
  }
}

///|
fn member_value(input : Json, key : Json) -> Bool raise InterpreterError {
  match (input, key) {
    (Null, _) => false
    (Object(fields), String(name)) => fields.contains(name)
    (Array(values), Number(index, ..)) =>
      !index.is_nan() && index >= 0 && index < values.length().to_double()
    _ =>
      raise EvalError(
        "has(" +
        json_to_text(key) +
        ") cannot be applied to: " +
        gh_describe(input),
      )
  }
}

///|
fn eval_argument_builtin_stream(
  name : String,
  args : Array[Expr],
  input : Json,
  env : Env,
  emit : (Json) -> Unit raise InterpreterError,
) -> Unit raise InterpreterError {
  if args.is_empty() {
    let selected = match name {
      "scalars" => !(input is (Array(_) | Object(_)))
      "arrays" => input is Array(_)
      "objects" => input is Object(_)
      "booleans" => input is (True | False)
      "numbers" => input is Number(_)
      "strings" => input is String(_)
      "nulls" => input is Null
      "iterables" => input is (Array(_) | Object(_))
      _ => false
    }
    if selected {
      emit(input)
    }
    return
  }
  if name == "split" && args.length() == 2 {
    let values : Array[Json] = []
    eval_regex_stream("splits", args, input, env, value => values.push(value))
    emit(Json(values))
    return
  }
  eval_stream_env(args[0], input, env, argument => {
    let error = name +
      "(" +
      json_to_text(argument) +
      ") cannot be applied to: " +
      gh_describe(input)
    match name {
      "has" => emit(Json(member_value(input, argument)))
      "in" => emit(Json(member_value(argument, input)))
      "contains" | "inside" => {
        let (container, value) = if name == "inside" {
          (argument, input)
        } else {
          (input, argument)
        }
        if @ast_internal.json_type_name(container) !=
          @ast_internal.json_type_name(value) {
          raise EvalError(
            "contains(" +
            json_to_text(value) +
            ") cannot be applied to: " +
            gh_describe(container),
          )
        }
        emit(Json(contains_value(container, value)))
      }
      "split" => {
        guard input is String(text) else {
          raise EvalError("split cannot be applied to: " + gh_describe(input))
        }
        guard argument is String(separator) else {
          raise EvalError(
            "split cannot be applied to: " + gh_describe(argument),
          )
        }
        emit(
          if separator.is_empty() {
            Json(text.iter().map(ch => Json(ch.to_string())).collect())
          } else {
            Json(
              text.split(separator).map(part => Json(part.to_owned())).collect(),
            )
          },
        )
      }
      "join" => {
        guard input is Array(values) && argument is String(separator) else {
          raise EvalError(error)
        }
        let output = StringBuilder()
        for index, value in values {
          if index > 0 {
            output.write_string(separator)
          }
          match value {
            String(value) => output.write_string(value)
            Null => ()
            Number(_) | True | False => output.write_string(json_to_text(value))
            _ =>
              raise EvalError(
                "cannot add: " +
                gh_describe(Json(output.to_string())) +
                " and " +
                gh_describe(value),
              )
          }
        }
        emit(Json(output.to_string()))
      }
      "startswith" | "endswith" | "ltrimstr" | "rtrimstr" => {
        guard input is String(text) && argument is String(part) else {
          raise EvalError(error)
        }
        emit(
          match name {
            "startswith" => Json(text.has_prefix(part))
            "endswith" => Json(text.has_suffix(part))
            "ltrimstr" =>
              Json(
                text.strip_prefix(part).map_or(text, value => value.to_owned()),
              )
            _ =>
              Json(
                text.strip_suffix(part).map_or(text, value => value.to_owned()),
              )
          },
        )
      }
      _ =>
        raise EvalError(
          "function not defined: " + function_key(name, args.length()),
        )
    }
  })
}
