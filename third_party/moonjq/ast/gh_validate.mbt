///|
/// gojq resolves function names before producing any output. MoonJQ's runtime
/// evaluator resolves calls lazily, so validate the full AST before streaming.
fn validate_functions(
  expr : Expr,
  functions : Map[String, Int32],
) -> Unit raise InterpreterError {
  match expr {
    Variable(name) =>
      if !functions.contains("$" + name) {
        raise EvalError("variable not defined: $" + name)
      }
    Label(name, body) => {
      let scope = functions.copy()
      scope["@label:" + name] = 0
      validate_functions(body, scope)
    }
    Break(name) =>
      if !functions.contains("@label:" + name) {
        raise EvalError("label not defined: $" + name)
      }
    Pipe(FunctionDef(name, params, body), next) => {
      let scope = functions.copy()
      scope[function_key(name, params.length())] = 0
      let body_scope = scope.copy()
      for parameter in params {
        body_scope[if parameter.has_prefix("$") {
          parameter
        } else {
          function_key(parameter, 0)
        }] = 0
      }
      validate_functions(body, body_scope)
      validate_functions(next, scope)
    }
    FunctionDef(name, params, body) => {
      let scope = functions.copy()
      scope[function_key(name, params.length())] = 0
      for parameter in params {
        scope[if parameter.has_prefix("$") {
          parameter
        } else {
          function_key(parameter, 0)
        }] = 0
      }
      validate_functions(body, scope)
    }
    FunctionCall(name, args) => {
      guard functions.contains(function_key(name, args.length())) ||
        (name == "error" && args.length() <= 1) ||
        regex_arity(name, args.length()) ||
        argument_builtin_arity(name, args.length()) ||
        ((name == "env" || name == "tonumber") && args.is_empty()) else {
        raise EvalError("function not defined: \{name}/\{args.length()}")
      }
      for argument in args {
        validate_functions(argument, functions)
      }
    }
    Pipe(left, right)
    | Comma(left, right)
    | Alternative(left, right)
    | DynamicIndex(left, right)
    | Operation(left, _, right)
    | AnyGen(left, right)
    | AllGen(left, right)
    | RangeFromTo(left, right)
    | RecurseWith(left, right)
    | Update(left, right)
    | Assign(left, right)
    | AddAssign(left, right)
    | SubAssign(left, right)
    | MulAssign(left, right)
    | DivAssign(left, right)
    | ModAssign(left, right)
    | AltAssign(left, right)
    | SetPath(left, right)
    | Until(left, right)
    | While(left, right) => {
      validate_functions(left, functions)
      validate_functions(right, functions)
    }
    Optional(inner)
    | Map(inner)
    | Select(inner)
    | SortBy(inner)
    | UniqueBy(inner)
    | GroupBy(inner)
    | Contains(inner)
    | Inside(inner)
    | In(inner)
    | WithEntries(inner)
    | MapValues(inner)
    | FirstGen(inner)
    | LastGen(inner)
    | Repeat(inner)
    | IndicesOf(inner)
    | IndexOf(inner)
    | MinBy(inner)
    | MaxBy(inner)
    | Walk(inner)
    | Path(inner)
    | RIndex(inner)
    | PathsWithFilter(inner)
    | GetPath(inner)
    | DelPaths(inner)
    | Limit(_, inner)
    | Pow(inner) => validate_functions(inner, functions)
    As(source, name, body) => {
      validate_functions(source, functions)
      let scope = functions.copy()
      scope["$" + name] = 0
      validate_functions(body, scope)
    }
    RangeWithStep(first, second, third) | IfThenElse(first, second, third) => {
      validate_functions(first, functions)
      validate_functions(second, functions)
      validate_functions(third, functions)
    }
    Reduce(source, name, init, update) => {
      validate_functions(source, functions)
      validate_functions(init, functions)
      let scope = functions.copy()
      scope["$" + name] = 0
      validate_functions(update, scope)
    }
    Foreach(source, name, init, update, extract) => {
      validate_functions(source, functions)
      validate_functions(init, functions)
      let scope = functions.copy()
      scope["$" + name] = 0
      validate_functions(update, scope)
      if extract is Some(expr) {
        validate_functions(expr, scope)
      }
    }
    ArrayConstruct(Some(inner)) => validate_functions(inner, functions)
    TryCatch(inner, handler) => {
      validate_functions(inner, functions)
      if handler is Some(expr) {
        validate_functions(expr, functions)
      }
    }
    ObjectConstruct(pairs) =>
      for (key, value) in pairs {
        validate_functions(key, functions)
        if value is Some(expr) {
          validate_functions(expr, functions)
        }
      }
    StringInterpolation(parts) =>
      for (_, value) in parts {
        if value is Some(expr) {
          validate_functions(expr, functions)
        }
      }
    _ => ()
  }
}
