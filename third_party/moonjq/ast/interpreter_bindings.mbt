///|
/// Evaluate variable lookup
fn eval_variable(name : String, env : Env) -> Iter[Json] raise InterpreterError {
  guard env.get(name) is Some(v) else {
    raise InvalidOperation("Undefined variable: $\{name}")
  }
  Iter::singleton(v)
}

///|
/// Evaluate function call
fn eval_function_call(
  name : String,
  args : Array[Expr],
  input : Json,
  env : Env,
) -> Iter[Json] raise InterpreterError {
  if env.get_function(name, args.length()) is Some(binding) {
    let results : Array[Json] = []
    for scope in function_scopes(binding, args, input, env) {
      eval_stream_env(binding.body, input, scope, value => results.push(value))
    }
    return results.iter()
  }
  if regex_arity(name, args.length()) {
    return eval_regex_call(name, args, input, env)
  }
  if argument_builtin_arity(name, args.length()) {
    return collect_stream(FunctionCall(name, args), input, env)
  }
  if name == "tonumber" && args.is_empty() {
    match input {
      Number(_) => return Iter::singleton(input)
      String(text) => {
        let message = "tonumber cannot be applied to " +
          Json(text).stringify() +
          ": invalid number"
        guard !text.is_empty() && text.trim() == text else {
          raise EvalError(message)
        }
        let digits : StringView = if text.has_prefix("-") ||
          text.has_prefix("+") {
          text[1:]
        } else {
          text
        }
        if !digits.is_empty() && digits.iter().all(c => c >= '0' && c <= '9') {
          let integer = @bigint.BigInt::from_string(digits.to_owned())
          return Iter::singleton(
            integer_json(if text.has_prefix("-") { -integer } else { integer }),
          )
        }
        let parsed = @string.parse_double(text) catch {
          _ => raise EvalError(message)
        }
        guard !parsed.is_nan() && !parsed.is_inf() else {
          raise EvalError(message)
        }
        let value = if text == "-0" { 0.0 } else { parsed }
        return Iter::singleton(Json::number(value))
      }
      _ =>
        raise EvalError("tonumber cannot be applied to: " + gh_describe(input))
    }
  }
  if name == "env" && args.is_empty() {
    return Iter::singleton(env.get("ENV").unwrap_or(Json::object(Map([]))))
  }
  if name == "error" && args.length() <= 1 {
    let values = if args.is_empty() {
      [input]
    } else {
      eval_with_env(args[0], input, env).collect()
    }
    if values.is_empty() {
      return Iter::empty()
    }
    raise UserError(values[0])
  }
  raise EvalError("function not defined: \{name}/\{args.length()}")
}

///|
/// Evaluate As binding
fn eval_as(
  expr : Expr,
  var_name : String,
  body : Expr,
  input : Json,
  env : Env,
) -> Iter[Json] raise InterpreterError {
  let results = eval_with_env(expr, input, env).collect()
  let all_results : Array[Json] = []
  for result in results {
    let new_env = env.set(var_name, result)
    for val in eval_with_env(body, input, new_env) {
      all_results.push(val)
    }
  }
  all_results.iter()
}
