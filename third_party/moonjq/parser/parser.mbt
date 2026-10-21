///|
/// Parse entry point
pub fn parse(input : String) -> @ast.Expr raise {
  let lexer = lex_state(input)
  let parser = Parser::new(lexer.tokens)
  parser.parse_definitions() catch {
    _ => {
      let (start, end) = lexer.spans
        .get(parser.pos)
        .unwrap_or((input.length(), input.length()))
      raise Located(start, input[start:end].to_owned())
    }
  }
}

///|
/// Parse function definitions followed by expression
fn Parser::parse_definitions(self : Parser) -> @ast.Expr raise ParseError {
  let main_expr = self.parse_pipe()
  // The whole query must be consumed; otherwise `. 1` or `."a"` would
  // silently parse as `.`.
  if self.current() is Some(t) && !(t is TEof) {
    raise UnexpectedToken(t.to_string(), "end of query")
  }
  main_expr
}
