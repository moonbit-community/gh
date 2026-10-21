///|
/// Parse pipe expression (lowest precedence)
fn Parser::parse_pipe(self : Parser) -> @ast.Expr raise ParseError {
  if self.current() == Some(TDef) {
    let outer = self.functions.copy()
    defer {
      self.functions = outer
    }
    let definition = self.parse_function_def()
    return Pipe(definition, self.parse_pipe())
  }
  let expr = self.parse_comma()
  if self.consume(TAs) {
    guard self.current() is Some(TVariable(var_name)) else {
      raise InvalidSyntax("Expected variable after 'as'")
    }
    self.advance()
    self.expect(TPipe)
    let body = self.parse_pipe()
    return As(expr, var_name, body)
  }
  if self.consume(TPipe) {
    Pipe(expr, self.parse_pipe())
  } else {
    expr
  }
}

///|
/// Parse comma expression
fn Parser::parse_comma(self : Parser) -> @ast.Expr raise ParseError {
  let mut current = self.parse_assignment()
  while self.consume(TComma) {
    let right = self.parse_assignment()
    current = Comma(current, right)
  }
  current
}
