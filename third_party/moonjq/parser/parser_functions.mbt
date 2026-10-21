///|
/// Parse function definition: def name(params): body;
fn Parser::parse_function_def(self : Parser) -> @ast.Expr raise ParseError {
  self.expect(TDef)
  guard self.current() is Some(TIdentifier(name)) else {
    raise UnexpectedToken("identifier", "function name")
  }
  self.advance()
  let params : Array[String] = []
  // Optional parameters
  if self.consume(TLParen) {
    if self.current() != Some(TRParen) {
      while true {
        let parameter = match self.current() {
          Some(TIdentifier(p)) => p
          Some(TVariable(p)) => "$" + p
          _ => raise UnexpectedToken("identifier", "parameter")
        }
        params.push(parameter)
        self.advance()
        if !self.consume(TSemicolon) {
          break
        }
      }
    }
    self.expect(TRParen)
  }
  self.expect(TColon)
  self.functions[name + "/" + params.length().to_string()] = true
  let outer = self.functions.copy()
  defer {
    self.functions = outer
  }
  for parameter in params {
    if !parameter.has_prefix("$") {
      self.functions[parameter + "/0"] = true
    }
  }
  let body = self.parse_pipe()
  self.expect(TSemicolon)
  FunctionDef(name, params, body)
}
