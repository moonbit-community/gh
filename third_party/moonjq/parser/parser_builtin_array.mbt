///|
/// Parse array built-ins
fn Parser::parse_builtin_array(
  self : Parser,
  name : String,
) -> @ast.Expr? raise ParseError {
  match name {
    "map" => {
      self.expect(TLParen)
      let expr = self.parse_pipe()
      self.expect(TRParen)
      Some(Map(expr))
    }
    "select" => {
      self.expect(TLParen)
      let expr = self.parse_pipe()
      self.expect(TRParen)
      Some(Select(expr))
    }
    "sort" => Some(Sort)
    "reverse" => Some(Reverse)
    "flatten" =>
      if self.consume(TLParen) {
        let depth = self.parse_slice_part()
        self.expect(TRParen)
        Some(Flatten(depth))
      } else {
        Some(Flatten(None))
      }
    "unique" => Some(Unique)
    "unique_by" => {
      self.expect(TLParen)
      let expr = self.parse_pipe()
      self.expect(TRParen)
      Some(UniqueBy(expr))
    }
    "combinations" => Some(Combinations)
    "transpose" => Some(Transpose)
    "indices" => {
      self.expect(TLParen)
      let expr = self.parse_pipe()
      self.expect(TRParen)
      Some(IndicesOf(expr))
    }
    "index" => {
      self.expect(TLParen)
      let expr = self.parse_pipe()
      self.expect(TRParen)
      Some(IndexOf(expr))
    }
    "sort_by" => {
      self.expect(TLParen)
      let expr = self.parse_pipe()
      self.expect(TRParen)
      Some(SortBy(expr))
    }
    "group_by" => {
      self.expect(TLParen)
      let expr = self.parse_pipe()
      self.expect(TRParen)
      Some(GroupBy(expr))
    }
    "nth" => {
      self.expect(TLParen)
      guard self.parse_slice_part() is Some(n) else {
        raise InvalidSyntax("nth expects number argument")
      }
      self.expect(TRParen)
      Some(Nth(n))
    }
    "rindex" => {
      self.expect(TLParen)
      let expr = self.parse_pipe()
      self.expect(TRParen)
      Some(RIndex(expr))
    }
    _ => None
  }
}
