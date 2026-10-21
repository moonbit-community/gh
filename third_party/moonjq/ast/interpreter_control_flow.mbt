///|
/// Evaluate IfThenElse
fn eval_if_then_else(
  cond : Expr,
  then_expr : Expr,
  else_expr : Expr,
  input : Json,
  env : Env,
) -> Iter[Json] raise InterpreterError {
  collect_stream(IfThenElse(cond, then_expr, else_expr), input, env)
}

///|
/// Evaluate TryCatch
fn eval_try_catch(
  try_expr : Expr,
  catch_opt : Expr?,
  input : Json,
  env : Env,
) -> Iter[Json] raise InterpreterError {
  collect_stream(TryCatch(try_expr, catch_opt), input, env)
}

///|
/// Evaluate Alternative
fn eval_alternative(
  left : Expr,
  right : Expr,
  input : Json,
  env : Env,
) -> Iter[Json] raise InterpreterError {
  collect_stream(Alternative(left, right), input, env)
}

///|
/// Evaluate Limit
fn eval_limit(
  n : Int32,
  expr : Expr,
  input : Json,
  env : Env,
) -> Iter[Json] raise InterpreterError {
  collect_stream(Limit(n, expr), input, env)
}

///|
/// Evaluate Until
fn eval_until(
  cond_expr : Expr,
  update_expr : Expr,
  input : Json,
  env : Env,
) -> Iter[Json] raise InterpreterError {
  let result = for current = input {
    let cond_results = eval_with_env(cond_expr, current, env).collect()
    match cond_results {
      [] => break current
      [True, ..] => break current
      _ => {
        let update_results = eval_with_env(update_expr, current, env).collect()
        match update_results {
          [] => break current
          [next, ..] => continue next
        }
      }
    }
  } where {
    proof_invariant: true,
    proof_reasoning: (
      #|`current` is always the initial input or the first value produced by
      #|the update expression. Each iteration either breaks immediately or
      #|continues with that next value; jq `until` may intentionally diverge
      #|when neither the condition nor the update causes termination.
    ),
  }
  Iter::singleton(result)
}

///|
/// Evaluate While
fn eval_while(
  cond_expr : Expr,
  update_expr : Expr,
  input : Json,
  env : Env,
) -> Iter[Json] raise InterpreterError {
  let results : Array[Json] = []
  let mut current = input
  while true {
    let cond_results = eval_with_env(cond_expr, current, env).collect()
    match cond_results {
      [] => break
      [first, ..] =>
        if !@ast_internal.is_truthy(first) {
          break
        } else {
          results.push(current)
          let update_results = eval_with_env(update_expr, current, env).collect()
          match update_results {
            [] => break
            [next, ..] => current = next
          }
        }
    }
  }
  results.iter()
}
