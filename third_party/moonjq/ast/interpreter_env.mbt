///|
/// Environment for variable and function bindings
priv struct Env {
  bindings : Map[String, Json]
  functions : Map[String, FunctionBinding]
  stops : Ref[Int32]
}

///|
priv struct FunctionBinding {
  body : Expr
  params : Array[String]
  closure : Env
  recursive_name : String?
}

///|
fn function_key(name : String, arity : Int32) -> String {
  name + "/" + arity.to_string()
}

///|
fn Env::new() -> Env {
  { bindings: Map([]), functions: Map([]), stops: Ref(0), }
}

///|
fn Env::get(self : Env, name : String) -> Json? {
  self.bindings.get(name)
}

///|
fn Env::set(self : Env, name : String, value : Json) -> Env {
  let new_bindings = self.bindings.copy()
  new_bindings[name] = value
  { bindings: new_bindings, functions: self.functions, stops: self.stops, }
}

///|
fn Env::with_binding(self : Env, name : String, value : Json) -> Env {
  let new_bindings = self.bindings.copy()
  let new_funcs = self.functions.copy()
  new_bindings[name] = value
  { bindings: new_bindings, functions: new_funcs, stops: self.stops, }
}

///|
fn Env::set_function(
  self : Env,
  name : String,
  body : Expr,
  params : Array[String],
) -> Env {
  self.with_function(name, {
    body,
    params,
    closure: self,
    recursive_name: Some(name),
  })
}

///|
fn Env::with_function(
  self : Env,
  name : String,
  binding : FunctionBinding,
) -> Env {
  let functions = self.functions.copy()
  functions[function_key(name, binding.params.length())] = binding
  { bindings: self.bindings, functions, stops: self.stops, }
}

///|
fn Env::get_function(
  self : Env,
  name : String,
  arity : Int32,
) -> FunctionBinding? {
  self.functions.get(function_key(name, arity))
}

///|
/// Value parameters bind each output; filter parameters capture the caller's
/// lexical environment and run later on the input at their call site.
fn function_scopes(
  binding : FunctionBinding,
  args : Array[Expr],
  input : Json,
  caller : Env,
) -> Array[Env] raise InterpreterError {
  let scopes : Array[Env] = []
  stream_function_scopes(binding, args, input, caller, scope => {
    scopes.push(scope)
  })
  scopes
}

///|
fn stream_function_scopes(
  binding : FunctionBinding,
  args : Array[Expr],
  input : Json,
  caller : Env,
  emit : (Env) -> Unit raise InterpreterError,
) -> Unit raise InterpreterError {
  let closure = match binding.recursive_name {
    Some(name) => binding.closure.with_function(name, binding)
    None => binding.closure
  }
  fn bind(index : Int32, scope : Env) -> Unit raise InterpreterError {
    if index == binding.params.length() {
      emit(scope)
      return
    }
    let parameter = binding.params[index]
    if parameter.has_prefix("$") {
      eval_stream_env(args[index], input, caller, value => {
        bind(index + 1, scope.set(parameter[1:].to_owned(), value))
      })
    } else {
      let filter = {
        body: args[index],
        params: [],
        closure: caller,
        recursive_name: None,
      }
      bind(index + 1, scope.with_function(parameter, filter))
    }
  }
  bind(0, closure)
}
