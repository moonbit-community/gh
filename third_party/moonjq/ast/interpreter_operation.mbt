///|
/// Evaluate binary operation expressions
fn eval_operation_expr(
  left : Expr,
  op : BinaryOp,
  right : Expr,
  input : Json,
  env : Env,
) -> Iter[Json] raise InterpreterError {
  collect_stream(Operation(left, op, right), input, env)
}
