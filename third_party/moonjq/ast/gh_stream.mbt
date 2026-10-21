///|
/// Local adaptation of MoonJQ 0.2.0 for gh's incremental output contract.
/// Retains the upstream parser, bindings, built-ins, and aggregate evaluators.
/// Source hashes and license are recorded in ../upstream.json and ../LICENSE.
pub fn eval_stream(
  expr : Expr,
  input : Json,
  emit : (Json) -> Unit raise InterpreterError,
  environment~ : Map[String, String] = Map([]),
) -> Unit raise InterpreterError {
  validate_functions(expr, { "$ENV": 0 })
  let fields : Map[String, Json] = Map([])
  for key, value in environment {
    fields[key] = Json(value)
  }
  eval_stream_env(
    expr,
    input,
    Env::new().set("ENV", Json::object(fields)),
    emit,
  )
}

///|
fn eval_stream_env(
  expr : Expr,
  input : Json,
  env : Env,
  emit : (Json) -> Unit raise InterpreterError,
) -> Unit raise InterpreterError {
  match expr {
    FirstGen(body) => stream_limit(1, body, input, env, emit)
    Limit(count, body) => stream_limit(count, body, input, env, emit)
    Repeat(body) =>
      while true {
        eval_stream_env(body, input, env, emit)
      }
    Select(condition) =>
      eval_stream_env(condition, input, env, value => {
        if @ast_internal.is_truthy(value) {
          emit(input)
        }
      })
    Operation(left, And, right) =>
      eval_stream_env(left, input, env, value => {
        if @ast_internal.is_truthy(value) {
          eval_stream_env(right, input, env, value => {
            emit(Json(@ast_internal.is_truthy(value)))
          })
        } else {
          emit(Json(false))
        }
      })
    Operation(left, Or, right) =>
      eval_stream_env(left, input, env, value => {
        if @ast_internal.is_truthy(value) {
          emit(Json(true))
        } else {
          eval_stream_env(right, input, env, value => {
            emit(Json(@ast_internal.is_truthy(value)))
          })
        }
      })
    Operation(left, op, right) =>
      eval_stream_env(right, input, env, b => {
        eval_stream_env(left, input, env, a => emit(eval_binary_op(op, a, b)))
      })
    Alternative(left, right) => {
      let mut found = false
      eval_stream_env(left, input, env, value => {
        if @ast_internal.is_truthy(value) {
          found = true
          emit(value)
        }
      })
      if !found {
        eval_stream_env(right, input, env, emit)
      }
    }
    ObjectConstruct(pairs) => stream_object(pairs, input, env, emit)
    DynamicIndex(base, index) =>
      eval_stream_env(index, input, env, key => {
        eval_stream_env(base, input, env, value => {
          emit(dynamic_index(value, key))
        })
      })
    FunctionCall(name, args) if env.get_function(name, args.length())
      is Some(binding) =>
      stream_function_scopes(binding, args, input, env, scope => {
        eval_stream_env(binding.body, input, scope, emit)
      })
    FunctionCall(name, args) if regex_arity(name, args.length()) =>
      eval_regex_stream(name, args, input, env, emit)
    FunctionCall(name, args) if argument_builtin_arity(name, args.length()) =>
      eval_argument_builtin_stream(name, args, input, env, emit)
    Label(name, body) =>
      eval_stream_env(body, input, env, emit) catch {
        BreakLabel(target) if name == target => ()
        error => raise error
      }
    Break(name) => raise BreakLabel(name)
    Pipe(FunctionDef(name, params, body), right) =>
      eval_stream_env(right, input, env.set_function(name, body, params), emit)
    Pipe(left, right) =>
      eval_stream_env(left, input, env, value => {
        eval_stream_env(right, value, env, emit)
      })
    Comma(left, right) => {
      eval_stream_env(left, input, env, emit)
      eval_stream_env(right, input, env, emit)
    }
    As(source, name, body) =>
      eval_stream_env(source, input, env, value => {
        eval_stream_env(body, input, env.set(name, value), emit)
      })
    IfThenElse(condition, yes, no) =>
      eval_stream_env(condition, input, env, value => {
        eval_stream_env(
          if @ast_internal.is_truthy(value) {
            yes
          } else {
            no
          },
          input,
          env,
          emit,
        )
      })
    TryCatch(body, handler) =>
      eval_stream_env(body, input, env, value => {
        emit(value) catch {
          error => raise Downstream(error)
        }
      }) catch {
        Downstream(error) => raise error
        BreakLabel(_) | StopStream(_) as error => raise error
        error =>
          if handler is Some(handler) {
            let value = match error {
              EvalError(value) => Json::string(value)
              UserError(value) => value
              _ => Json::string(error.to_string())
            }
            eval_stream_env(handler, value, env, emit)
          }
      }
    Optional(body) =>
      eval_stream_env(body, input, env, value => {
        emit(value) catch {
          error => raise Downstream(error)
        }
      }) catch {
        Downstream(error) => raise error
        BreakLabel(_) | StopStream(_) as error => raise error
        _ => ()
      }
    _ =>
      for value in eval_with_env(expr, input, env) {
        emit(value)
      }
  }
}

///|
fn collect_stream(
  expr : Expr,
  input : Json,
  env : Env,
) -> Iter[Json] raise InterpreterError {
  let values : Array[Json] = []
  eval_stream_env(expr, input, env, value => values.push(value))
  values.iter()
}

///|
/// Each early-stop frame owns a distinct tag. A nested first/limit must never
/// swallow a stop raised by its caller, nor can jq's try/optional catch it.
fn stream_limit(
  count : Int32,
  body : Expr,
  input : Json,
  env : Env,
  emit : (Json) -> Unit raise InterpreterError,
) -> Unit raise InterpreterError {
  if count < 0 {
    raise EvalError("limit doesn't support negative count")
  }
  if count == 0 {
    return
  }
  env.stops.val += 1
  let tag = env.stops.val
  let mut remaining = count
  eval_stream_env(body, input, env, value => {
    emit(value)
    remaining -= 1
    if remaining == 0 {
      raise StopStream(tag)
    }
  }) catch {
    StopStream(other) if other == tag => ()
    error => raise error
  }
}

///|
fn stream_object(
  pairs : Array[(Expr, Expr?)],
  input : Json,
  env : Env,
  emit : (Json) -> Unit raise InterpreterError,
) -> Unit raise InterpreterError {
  fn build(
    index : Int32,
    object : Map[String, Json],
  ) -> Unit raise InterpreterError {
    if index == pairs.length() {
      emit(Json::object(object))
      return
    }
    let (key, value) = pairs[index]
    eval_stream_env(key, input, env, name => {
      guard name is String(name) else {
        raise TypeMismatch("string", @ast_internal.json_type_name(name))
      }
      eval_stream_env(value.unwrap_or(Key(name)), input, env, item => {
        let fields = object.copy()
        fields[name] = item
        build(index + 1, fields)
      })
    })
  }
  build(0, Map([]))
}
