///|
/// Parse built-in functions
fn Parser::parse_builtin(
  self : Parser,
  name : String,
) -> @ast.Expr raise ParseError {
  if self.functions.keys().any(key => key.has_prefix(name + "/")) {
    let start = self.pos
    let call = self.parse_function_call(name)
    if call is FunctionCall(_, args) &&
      self.functions.contains(name + "/" + args.length().to_string()) {
      return call
    }
    self.pos = start
  }
  match self.parse_builtin_by_name(name) {
    Some(expr) => expr
    None => self.parse_function_call(name)
  }
}

///|
fn Parser::parse_function_call(
  self : Parser,
  name : String,
) -> @ast.Expr raise ParseError {
  if self.current() == Some(TLParen) {
    self.advance()
    let args : Array[@ast.Expr] = []
    // Check if there's an expression (not just closing paren)
    if self.current() != Some(TRParen) {
      args.push(self.parse_pipe())
      while self.consume(TSemicolon) {
        args.push(self.parse_pipe())
      }
    }
    self.expect(TRParen)
    FunctionCall(name, args)
  } else {
    FunctionCall(name, [])
  }
}

///|
/// Parse built-ins by category - try each category in order
fn Parser::parse_builtin_by_name(
  self : Parser,
  name : String,
) -> @ast.Expr? raise ParseError {
  // Regex parameters are filters, including replacement expressions.
  if name is ("test" | "match" | "capture" | "scan" | "splits" | "sub" | "gsub") {
    return None
  }
  if name
    is ("split"
    | "join"
    | "startswith"
    | "endswith"
    | "ltrimstr"
    | "rtrimstr"
    | "contains"
    | "inside"
    | "has"
    | "in") {
    return None
  }
  if self.parse_builtin_core(name) is Some(expr) {
    return Some(expr)
  }
  if self.parse_builtin_numeric(name) is Some(expr) {
    return Some(expr)
  }
  if self.parse_builtin_array(name) is Some(expr) {
    return Some(expr)
  }
  if self.parse_builtin_object(name) is Some(expr) {
    return Some(expr)
  }
  if self.parse_builtin_string(name) is Some(expr) {
    return Some(expr)
  }
  if self.parse_builtin_path(name) is Some(expr) {
    return Some(expr)
  }
  self.parse_builtin_flow(name)
}
