///|
/// Parse flow control built-ins
fn Parser::parse_builtin_flow_control(
  self : Parser,
  name : String,
) -> @ast.Expr? raise ParseError {
  match name {
    "limit" => {
      self.expect(TLParen)
      guard self.parse_slice_part() is Some(n) else {
        raise InvalidSyntax("limit expects number argument")
      }
      self.expect(TSemicolon)
      let expr = self.parse_pipe()
      self.expect(TRParen)
      Some(Limit(n, expr))
    }
    "until" => {
      self.expect(TLParen)
      let cond = self.parse_pipe()
      self.expect(TSemicolon)
      let update = self.parse_pipe()
      self.expect(TRParen)
      Some(Until(cond, update))
    }
    "while" => {
      self.expect(TLParen)
      let cond = self.parse_pipe()
      self.expect(TSemicolon)
      let update = self.parse_pipe()
      self.expect(TRParen)
      Some(While(cond, update))
    }
    _ => None
  }
}
