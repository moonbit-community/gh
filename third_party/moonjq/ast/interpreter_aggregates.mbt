///|
/// Evaluate Reduce
fn eval_reduce(
  expr : Expr,
  var_name : String,
  init_expr : Expr,
  update_expr : Expr,
  input : Json,
  env : Env,
) -> Iter[Json] raise InterpreterError {
  let init_results = eval_with_env(init_expr, input, env).collect()
  match init_results {
    [] => Iter::singleton(null)
    [first, ..] => {
      let accumulator = eval_with_env(expr, input, env).fold(init=first, fn(
        acc,
        item,
      ) raise InterpreterError {
        let new_env = env.set(var_name, item)
        let update_results = eval_with_env(update_expr, acc, new_env).collect()
        match update_results {
          [] => acc
          [next, ..] => next
        }
      })
      Iter::singleton(accumulator)
    }
  }
}

///|
/// Evaluate SortBy
fn eval_sort_by(
  expr : Expr,
  input : Json,
  env : Env,
) -> Iter[Json] raise InterpreterError {
  guard input is Array(arr) else {
    raise TypeMismatch("array", @ast_internal.json_type_name(input))
  }
  let pairs = ordered_keys(expr, arr, env)
  let sorted = pairs.map(fn(p) { p.2 })
  Iter::singleton(Json::array(sorted))
}

///|
/// Evaluate GroupBy
fn eval_group_by(
  expr : Expr,
  input : Json,
  env : Env,
) -> Iter[Json] raise InterpreterError {
  guard input is Array(arr) else {
    raise TypeMismatch("array", @ast_internal.json_type_name(input))
  }
  let keyed = ordered_keys(expr, arr, env)
  let groups : Array[Array[Json]] = []
  let mut previous : Json? = None
  for (key, _, value) in keyed {
    if previous.map_or(true, old => compare_json(old, key) != 0) {
      groups.push([])
      previous = Some(key)
    }
    groups[groups.length() - 1].push(value)
  }
  let result = groups.map(Json::array)
  Iter::singleton(Json::array(result))
}

///|
fn ordered_keys(
  expr : Expr,
  arr : Array[Json],
  env : Env,
) -> Array[(Json, Int32, Json)] raise InterpreterError {
  let keyed : Array[(Json, Int32, Json)] = []
  for index, elem in arr {
    keyed.push(
      (Json::array(eval_with_env(expr, elem, env).collect()), index, elem),
    )
  }
  keyed.sort_by((left, right) => {
    let order = compare_json(left.0, right.0)
    if order == 0 {
      left.1.compare(right.1)
    } else {
      order
    }
  })
  keyed
}

///|
/// Evaluate Any
fn eval_any(input : Json) -> Iter[Json] raise InterpreterError {
  guard input is Array(arr) else {
    raise TypeMismatch("array", @ast_internal.json_type_name(input))
  }
  Iter::singleton(Json::boolean(arr.any(@ast_internal.is_truthy)))
}

///|
/// Evaluate All
fn eval_all(input : Json) -> Iter[Json] raise InterpreterError {
  guard input is Array(arr) else {
    raise TypeMismatch("array", @ast_internal.json_type_name(input))
  }
  Iter::singleton(Json::boolean(arr.all(@ast_internal.is_truthy)))
}
