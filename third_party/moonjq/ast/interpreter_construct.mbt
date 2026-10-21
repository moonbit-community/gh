///|
/// Evaluate array construction
fn eval_array_construct(
  expr_opt : Expr?,
  input : Json,
  env : Env,
) -> Iter[Json] raise InterpreterError {
  match expr_opt {
    None => Iter::singleton(Json::array([]))
    Some(e) => {
      let results = collect_stream(e, input, env).collect()
      Iter::singleton(Json::array(results))
    }
  }
}

///|
/// Evaluate object construction
fn eval_object_construct(
  pairs : Array[(Expr, Expr?)],
  input : Json,
  env : Env,
) -> Iter[Json] raise InterpreterError {
  collect_stream(ObjectConstruct(pairs), input, env)
}
