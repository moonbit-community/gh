///|
/// Parse postfix operators
fn Parser::parse_postfix(self : Parser) -> @ast.Expr raise ParseError {
  let mut expr = self.parse_primary()
  while true {
    match self.current() {
      Some(TQuestion) => {
        self.advance()
        expr = Optional(expr)
        continue
      }
      Some(TLBracket) => {
        self.advance()
        expr = self.parse_index_or_slice(expr)
        continue
      }
      Some(TDot) => {
        self.advance()
        expr = self.parse_field_access(expr)
        continue
      }
      _ => break
    }
  }
  expr
}

///|
/// Parse array index or slice
fn Parser::parse_index_or_slice(
  self : Parser,
  base : @ast.Expr,
) -> @ast.Expr raise ParseError {
  if self.consume(TRBracket) {
    return Pipe(base, Index([]))
  }
  let saved = self.pos
  let start_or_index = self.parse_slice_part()
  if self.consume(TColon) {
    let end = self.parse_slice_part()
    self.expect(TRBracket)
    Pipe(base, Slice(start_or_index, end))
  } else {
    self.pos = saved
    let index = self.parse_pipe()
    self.expect(TRBracket)
    DynamicIndex(base, index)
  }
}

///|
/// Parse optional integer for slice
fn Parser::parse_slice_part(self : Parser) -> Int32? {
  match self.current() {
    Some(TNumber(n, ..)) => {
      self.advance()
      Some(n.to_int())
    }
    Some(TMinus) => {
      self.advance()
      guard self.current() is Some(TNumber(n, ..)) else {
        self.pos -= 1
        return None
      }
      self.advance()
      Some(-n.to_int())
    }
    _ => None
  }
}

///|
/// Parse field access after dot
fn Parser::parse_field_access(
  self : Parser,
  base : @ast.Expr,
) -> @ast.Expr raise ParseError {
  match self.current() {
    Some(TIdentifier(name)) => {
      self.advance()
      Pipe(base, Key(name))
    }
    Some(TString(name)) => {
      // ."key"
      self.advance()
      Pipe(base, Key(name))
    }
    Some(TLBracket) => {
      self.advance()
      self.parse_index_or_slice(base)
    }
    Some(TDot) => {
      self.advance()
      Recurse
    }
    _ => base
  }
}
