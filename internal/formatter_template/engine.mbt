// A runtime template engine — moonctl's faithful equivalent of goctl's
// `text/template`. It parses a template into a node tree once, then renders it
// against a dynamic `Value` (MoonBit has no reflection, so template data is an
// explicit tagged value the way `encoding/json` models it). Supports `{{.Field}}`
// interpolation, `{{if}}/{{else}}/{{range}}/{{with}}/{{end}}`, `$variable`
// assignment, `|` pipelines, parenthesised sub-pipelines, `{{- -}}` whitespace
// trimming, `{{/* comments */}}`, and a library of pipeline functions. Pure and
// all-backend.

///|
/// Dynamic template data. `.Field` lookups resolve against `Dict`; `range`
/// iterates `List` (index/element) or `Dict` (sorted key/value). This is the
/// explicit stand-in for the arbitrary Go values goctl reflects over.
pub(all) enum Value {
  Null
  Bool(Bool)
  Int(Int64)
  Float(Double)
  Str(String)
  List(Array[Value])
  Dict(Map[String, Value])
}

///|
/// A template parse or execution failure, carrying a human-readable message.
pub suberror TemplateError {
  ParseError(String)
  ExecError(String)
  LocatedExec(String)
  LocatedParse(Int32, String)
  LoopControl(Bool)
  CommandError(Int32, String, String)
}

///|
impl Show for TemplateError with fn output(self, logger) {
  match self {
    ParseError(m) => logger.write_string("template parse error: " + m)
    ExecError(m) => logger.write_string("template exec error: " + m)
    LocatedExec(m) => logger.write_string(m)
    LocatedParse(line, m) => logger.write_string("template: :\{line}: " + m)
    LoopControl(stop) =>
      logger.write_string(if stop { "break" } else { "continue" })
    CommandError(_, _, message) => logger.write_string(message)
  }
}

///|
/// A pipeline function: it receives the already-evaluated argument list (with the
/// piped-in value, if any, appended last, mirroring Go) and returns a `Value`.
pub type FuncFn = (Array[Value]) -> Value raise TemplateError

// ── AST ──────────────────────────────────────────────────────────────────────

///|
priv enum Arg {
  Dot
  Field(Array[String])
  Var(String, Array[String])
  StrLit(String)
  IntLit(Int64)
  FloatLit(Double)
  BoolLit(Bool)
  NilLit
  Sub(Array[Command])
}

///|
priv struct Command {
  fn_ : String?
  args : Array[Arg]
  offset : Int32
}

///|
priv enum Node {
  Located(Int32, Int32, String, Node)
  Scope(Array[Node])
  Control(Bool)
  Text(String)
  Action(Array[Command])
  Assign(String, Bool, Array[Command])
  IfNode(Array[Command], Array[Node], Array[Node])
  RangeNode(Array[Command], String?, String?, Bool, Array[Node], Array[Node])
  WithNode(Array[Command], Array[Node], Array[Node])
  Invoke(String, Array[Command]?)
}

// ── Lexing: raw source → text / action pieces ────────────────────────────────

///|
priv enum Piece {
  PText(String)
  PAction(String, Int32, Int32)
}

///|
/// Index of the `}}` that closes an action started at `from`, skipping `"…"` and
/// `` `…` `` string literals so a `}}` inside a string is not mistaken for the
/// delimiter. Returns `-1` if unterminated.
fn find_close(src : String, from : Int32) -> Int32 {
  if trim_left_ws(src[from:].to_owned()).has_prefix("/*") {
    guard src[from:].split_once("*/") is Some((body, _)) else { return -1 }
    let mut cursor = from + body.length() + 2
    while cursor < src.length() && is_ws(src[cursor]) {
      cursor += 1
    }
    if cursor < src.length() && src[cursor] == '-' {
      cursor += 1
    }
    if src[cursor:].has_prefix("}}") {
      return cursor
    } else {
      return -1
    }
  }
  let n = src.length()
  let mut i = from
  while i < n {
    let c = src[i]
    if c == '"' {
      i += 1
      while i < n && src[i] != '"' {
        if src[i] == '\\' {
          i += 2
        } else {
          i += 1
        }
      }
      i += 1
    } else if c == '`' {
      i += 1
      while i < n && src[i] != '`' {
        i += 1
      }
      i += 1
    } else if c == '}' && i + 1 < n && src[i + 1] == '}' {
      return i
    } else {
      i += 1
    }
  }
  -1
}

///|
fn trim_left_ws(s : String) -> String {
  let n = s.length()
  let mut a = 0
  while a < n && is_ws(s[a]) {
    a += 1
  }
  s[a:n].to_owned()
}

///|
fn trim_right_ws(s : String) -> String {
  let mut b = s.length()
  while b > 0 && is_ws(s[b - 1]) {
    b -= 1
  }
  s[0:b].to_owned()
}

///|
/// Split `src` into literal-text and action pieces, honouring `{{- -}}`
/// whitespace-trim markers and dropping `{{/* comments */}}`.
fn scan(src : String) -> Array[Piece] raise TemplateError {
  let pieces : Array[Piece] = []
  let n = src.length()
  let mut i = 0
  let mut text_start = 0
  let mut trim_next_left = false
  while i < n {
    if src[i] == '{' && i + 1 < n && src[i + 1] == '{' {
      let mut body_start = i + 2
      let mut left_trim_prev = false
      if body_start < n &&
        src[body_start] == '-' &&
        body_start + 1 < n &&
        is_ws(src[body_start + 1]) {
        left_trim_prev = true
        body_start += 1
      }
      let mut t = src[text_start:i].to_owned()
      if trim_next_left {
        t = trim_left_ws(t)
      }
      if left_trim_prev {
        t = trim_right_ws(t)
      }
      if t != "" {
        pieces.push(PText(t))
      }
      trim_next_left = false
      let close = find_close(src, body_start)
      if close < 0 {
        raise ParseError("unclosed action, missing '}}'")
      }
      let mut body_end = close
      let mut right_trim_next = false
      if body_end - 1 >= body_start &&
        src[body_end - 1] == '-' &&
        body_end - 2 >= body_start &&
        is_ws(src[body_end - 2]) {
        right_trim_next = true
        body_end -= 1
      }
      let body = trim(src[body_start:body_end].to_owned())
      if starts_with(body, "/*") {
        // comment — emit nothing
        ()
      } else {
        let start = body_start +
          src[body_start:body_end].length() -
          trim_left_ws(src[body_start:body_end].to_owned()).length()
        let prefix = src[:start].to_owned()
        let lines = prefix.split("\n").collect()
        pieces.push(
          PAction(
            body,
            lines.length(),
            @utf8.encode(lines.last().unwrap().to_owned()).length(),
          ),
        )
      }
      trim_next_left = right_trim_next
      i = close + 2
      text_start = i
    } else {
      i += 1
    }
  }
  let mut t = src[text_start:n].to_owned()
  if trim_next_left {
    t = trim_left_ws(t)
  }
  if t != "" {
    pieces.push(PText(t))
  }
  pieces
}

// ── Lexing: action body → tokens ─────────────────────────────────────────────

///|
priv enum Tok {
  TWord(String, Int32)
  TStr(String, Int32)
  TPipe
  TLparen
  TRparen
  TAssign
  TEq
  TComma
}

///|
fn is_digit(c : UInt16) -> Bool {
  c >= '0' && c <= '9'
}

///|
/// Tokenise one action body: identifiers/fields/variables/numbers become
/// `TWord`, quoted and raw strings become `TStr`, and `|`, `(`, `)`, `,`, `:=`,
/// `=` become their own tokens.
fn lex_action(body : String) -> Array[Tok] raise TemplateError {
  let toks : Array[Tok] = []
  let n = body.length()
  let mut i = 0
  while i < n {
    let c = body[i]
    if is_ws(c) {
      i += 1
    } else if c == '|' {
      toks.push(TPipe)
      i += 1
    } else if c == '(' {
      toks.push(TLparen)
      i += 1
    } else if c == ')' {
      toks.push(TRparen)
      i += 1
    } else if c == ',' {
      toks.push(TComma)
      i += 1
    } else if c == ':' && i + 1 < n && body[i + 1] == '=' {
      toks.push(TAssign)
      i += 2
    } else if c == '=' {
      toks.push(TEq)
      i += 1
    } else if c == '"' {
      let start = i
      i += 1
      let sb = StringBuilder()
      let mut done = false
      while !done {
        if i >= n {
          raise ParseError("unterminated string literal")
        }
        let ch = body[i]
        if ch == '"' {
          i += 1
          done = true
        } else if ch == '\\' && i + 1 < n {
          let e = body[i + 1]
          let code = if e == 'n' {
            10
          } else if e == 't' {
            9
          } else if e == 'r' {
            13
          } else {
            e.to_int()
          }
          sb.write_char(code.unsafe_to_char())
          i += 2
        } else {
          sb.write_char(ch.to_int().unsafe_to_char())
          i += 1
        }
      }
      toks.push(TStr(sb.to_string(), start))
    } else if c == '`' {
      i += 1
      let start = i
      while i < n && body[i] != '`' {
        i += 1
      }
      if i >= n {
        raise ParseError("unterminated raw string literal")
      }
      toks.push(TStr(body[start:i].to_owned(), start - 1))
      i += 1
    } else {
      let start = i
      while i < n {
        let d = body[i]
        if is_ws(d) ||
          d == '|' ||
          d == '(' ||
          d == ')' ||
          d == ',' ||
          d == '"' ||
          d == '`' ||
          d == '=' ||
          (d == ':' && i + 1 < n && body[i + 1] == '=') {
          break
        }
        i += 1
      }
      toks.push(TWord(body[start:i].to_owned(), start))
    }
  }
  toks
}

// ── Parsing: tokens → commands ───────────────────────────────────────────────

///|
/// Split `s` on `ch` (no quote handling; for `.a.b` field chains and `$var`
/// names).
fn split_char(s : String, ch : UInt16) -> Array[String] {
  let out : Array[String] = []
  let n = s.length()
  let mut start = 0
  for i = 0; i <= n; i = i + 1 {
    if i == n || s[i] == ch {
      out.push(s[start:i].to_owned())
      start = i + 1
    }
  }
  out
}

///|
/// True when `w` is a value token (field, variable, literal, number) rather than
/// a bare function-name identifier.
fn is_value_word(w : String) -> Bool {
  if w.length() == 0 {
    return false
  }
  let c0 = w[0]
  if c0 == '.' || c0 == '$' {
    return true
  }
  if w == "true" || w == "false" || w == "nil" {
    return true
  }
  if is_digit(c0) {
    return true
  }
  if (c0 == '-' || c0 == '+') && w.length() > 1 && is_digit(w[1]) {
    return true
  }
  false
}

///|
fn parse_int_manual(w : String) -> Int64 raise TemplateError {
  let n = w.length()
  let mut i = 0
  let mut neg = false
  if n > 0 && (w[0] == '-' || w[0] == '+') {
    neg = w[0] == '-'
    i = 1
  }
  if i >= n {
    raise ParseError("malformed number '" + w + "'")
  }
  let mut v : Int64 = 0
  while i < n {
    let c = w[i]
    if !is_digit(c) {
      raise ParseError("malformed integer '" + w + "'")
    }
    v = v * 10L + (c.to_int() - 48).to_int64()
    i += 1
  }
  if neg {
    -v
  } else {
    v
  }
}

///|
fn parse_double_manual(w : String) -> Double raise TemplateError {
  let n = w.length()
  let mut i = 0
  let mut neg = false
  if n > 0 && (w[0] == '-' || w[0] == '+') {
    neg = w[0] == '-'
    i = 1
  }
  let mut int_part = 0.0
  let mut saw_digit = false
  while i < n && is_digit(w[i]) {
    int_part = int_part * 10.0 + (w[i].to_int() - 48).to_double()
    saw_digit = true
    i += 1
  }
  let mut frac = 0.0
  let mut scale = 1.0
  if i < n && w[i] == '.' {
    i += 1
    while i < n && is_digit(w[i]) {
      scale = scale / 10.0
      frac = frac + (w[i].to_int() - 48).to_double() * scale
      saw_digit = true
      i += 1
    }
  }
  let mut value = int_part + frac
  if i < n && (w[i] == 'e' || w[i] == 'E') {
    i += 1
    let mut exp_neg = false
    if i < n && (w[i] == '-' || w[i] == '+') {
      exp_neg = w[i] == '-'
      i += 1
    }
    let mut exp = 0
    while i < n && is_digit(w[i]) {
      exp = exp * 10 + (w[i].to_int() - 48)
      i += 1
    }
    let mut factor = 1.0
    for _k = 0; _k < exp; _k = _k + 1 {
      factor = factor * 10.0
    }
    value = if exp_neg { value / factor } else { value * factor }
  }
  if i != n || !saw_digit {
    raise ParseError("malformed number '" + w + "'")
  }
  if neg {
    -value
  } else {
    value
  }
}

///|
fn parse_number(w : String) -> Arg raise TemplateError {
  let mut is_float = false
  for i = 0; i < w.length(); i = i + 1 {
    let c = w[i]
    if c == '.' || c == 'e' || c == 'E' {
      is_float = true
    }
  }
  if is_float {
    FloatLit(parse_double_manual(w))
  } else {
    IntLit(parse_int_manual(w))
  }
}

///|
/// Classify a value word into an `Arg`; raises when it is actually a bare
/// function name (only valid as the first word of a command).
fn classify_value(w : String) -> Arg raise TemplateError {
  if w.length() == 0 {
    raise ParseError("empty token")
  }
  if w == "." {
    return Dot
  }
  let c0 = w[0]
  if c0 == '.' {
    let parts = split_char(w[1:].to_owned(), '.')
    let chain : Array[String] = []
    for p in parts {
      if p != "" {
        chain.push(p)
      }
    }
    return Field(chain)
  }
  if w == "$" {
    return Var("", [])
  }
  if c0 == '$' {
    let parts = split_char(w[1:].to_owned(), '.')
    let chain : Array[String] = []
    for i = 1; i < parts.length(); i = i + 1 {
      if parts[i] != "" {
        chain.push(parts[i])
      }
    }
    return Var(parts[0], chain)
  }
  if w == "true" {
    return BoolLit(true)
  }
  if w == "false" {
    return BoolLit(false)
  }
  if w == "nil" {
    return NilLit
  }
  if is_digit(c0) ||
    ((c0 == '-' || c0 == '+') && w.length() > 1 && is_digit(w[1])) {
    return parse_number(w)
  }
  raise ParseError(
    "unexpected identifier '" +
    w +
    "'; a function name is only valid as the first word of a command",
  )
}

///|
priv struct TokCursor {
  toks : Array[Tok]
  mut pos : Int32
}

///|
fn TokCursor::expect_rparen(self : TokCursor) -> Unit raise TemplateError {
  if self.pos < self.toks.length() {
    match self.toks[self.pos] {
      TRparen => self.pos += 1
      _ => raise ParseError("expected ')'")
    }
  } else {
    raise ParseError("expected ')'")
  }
}

///|
fn TokCursor::parse_command(self : TokCursor) -> Command raise TemplateError {
  if self.pos >= self.toks.length() {
    raise ParseError("expected a command")
  }
  match self.toks[self.pos] {
    TStr(s, offset) => {
      self.pos += 1
      { fn_: None, args: [StrLit(s)], offset, }
    }
    TLparen => {
      self.pos += 1
      let sub = self.parse_pipeline()
      self.expect_rparen()
      { fn_: None, args: [Sub(sub)], offset: sub[0].offset, }
    }
    TWord(w, offset) => {
      self.pos += 1
      if is_value_word(w) {
        { fn_: None, args: [classify_value(w)], offset, }
      } else {
        let args : Array[Arg] = []
        let mut stop = false
        while !stop {
          if self.pos >= self.toks.length() {
            break
          }
          match self.toks[self.pos] {
            TPipe => stop = true
            TRparen => stop = true
            TStr(s, _) => {
              args.push(StrLit(s))
              self.pos += 1
            }
            TLparen => {
              self.pos += 1
              let sub = self.parse_pipeline()
              self.expect_rparen()
              args.push(Sub(sub))
            }
            TWord(aw, _) => {
              args.push(classify_value(aw))
              self.pos += 1
            }
            TComma => raise ParseError("unexpected ',' in arguments")
            TAssign => raise ParseError("unexpected ':=' in arguments")
            TEq => raise ParseError("unexpected '=' in arguments")
          }
        }
        { fn_: Some(w), args, offset, }
      }
    }
    _ => raise ParseError("unexpected token; expected a command")
  }
}

///|
fn TokCursor::parse_pipeline(
  self : TokCursor,
) -> Array[Command] raise TemplateError {
  let cmds : Array[Command] = []
  for ;; {
    cmds.push(self.parse_command())
    if self.pos < self.toks.length() {
      match self.toks[self.pos] {
        TPipe => self.pos += 1
        _ => break
      }
    } else {
      break
    }
  }
  cmds
}

///|
/// Parse the pipeline that starts at token `start`, requiring every token to be
/// consumed.
fn pipeline_from(
  toks : Array[Tok],
  start : Int32,
) -> Array[Command] raise TemplateError {
  let tc = { toks, pos: start, }
  let cmds = tc.parse_pipeline()
  if tc.pos != toks.length() {
    raise ParseError("unexpected trailing tokens in action")
  }
  cmds
}

// ── Parsing: pieces → node tree ──────────────────────────────────────────────

///|
priv struct Parser {
  pieces : Array[Piece]
  mut pos : Int32
  definitions : Map[String, Array[Node]]
}

///|
fn first_word(toks : Array[Tok]) -> String {
  if toks.length() == 0 {
    return ""
  }
  match toks[0] {
    TWord(w, _) => w
    _ => ""
  }
}

///|
fn is_word(t : Tok, s : String) -> Bool {
  match t {
    TWord(w, _) => w == s
    _ => false
  }
}

///|
fn find_tassign(toks : Array[Tok]) -> Int32 {
  for i = 0; i < toks.length(); i = i + 1 {
    match toks[i] {
      TAssign | TEq => return i
      _ => ()
    }
  }
  -1
}

///|
fn is_assignment(toks : Array[Tok]) -> Bool {
  if toks.length() < 2 {
    return false
  }
  let starts_var = match toks[0] {
    TWord(w, _) => w.length() > 0 && w[0] == '$'
    _ => false
  }
  if !starts_var {
    return false
  }
  match toks[1] {
    TAssign => true
    TEq => true
    _ => false
  }
}

///|
fn build_assign(toks : Array[Tok]) -> Node raise TemplateError {
  let name = match toks[0] {
    TWord(w, _) => w[1:].to_owned()
    _ => raise ParseError("malformed variable assignment")
  }
  Assign(name, toks[1] is TAssign, pipeline_from(toks, 2))
}

///|
fn drop_first(toks : Array[Tok]) -> Array[Tok] {
  let out : Array[Tok] = []
  for i = 1; i < toks.length(); i = i + 1 {
    out.push(toks[i])
  }
  out
}

///|
fn Parser::parse_if(
  self : Parser,
  toks : Array[Tok],
) -> Node raise TemplateError {
  let (pipe, declaration) = condition_pipeline(toks)
  let (then_nodes, term) = self.parse_list()
  if term.is_empty() {
    raise ParseError("unexpected EOF")
  }
  let tterm = lex_action(term)
  let kw = first_word(tterm)
  let else_nodes : Array[Node] = if kw == "end" {
    []
  } else if kw == "else" {
    if tterm.length() >= 2 && is_word(tterm[1], "if") {
      [self.parse_if(drop_first(tterm))]
    } else {
      let (e, term2) = self.parse_list()
      if first_word(lex_action(term2)) != "end" {
        raise ParseError("expected {{end}} to close {{if}}")
      }
      e
    }
  } else {
    raise ParseError("expected {{else}} or {{end}} to close {{if}}")
  }
  let node = IfNode(pipe, then_nodes, else_nodes)
  match declaration {
    Some(binding) => Scope([binding, node])
    None => node
  }
}

///|
fn condition_pipeline(
  toks : Array[Tok],
) -> (Array[Command], Node?) raise TemplateError {
  let condition = drop_first(toks)
  if is_assignment(condition) {
    let declaration = build_assign(condition)
    let name = match condition[0] {
      TWord(value, _) => value[1:].to_owned()
      _ => raise ParseError("expected variable")
    }
    ([{ fn_: None, args: [Var(name, [])], offset: 0, }], Some(declaration))
  } else {
    (pipeline_from(toks, 1), None)
  }
}

///|
fn Parser::parse_range(
  self : Parser,
  toks : Array[Tok],
) -> Node raise TemplateError {
  let assign_idx = find_tassign(toks)
  let mut key_var : String? = None
  let mut val_var : String? = None
  let pipe = if assign_idx >= 0 {
    let names : Array[String] = []
    for i = 1; i < assign_idx; i = i + 1 {
      match toks[i] {
        TWord(w, _) =>
          if w.length() > 0 && w[0] == '$' {
            names.push(w[1:].to_owned())
          } else {
            raise ParseError("range: expected a $variable")
          }
        TComma => ()
        _ => raise ParseError("range: malformed variable list")
      }
    }
    if names.length() == 1 {
      val_var = Some(names[0])
    } else if names.length() == 2 {
      key_var = Some(names[0])
      val_var = Some(names[1])
    } else {
      raise ParseError("range: expected 1 or 2 variables before ':='")
    }
    pipeline_from(toks, assign_idx + 1)
  } else {
    pipeline_from(toks, 1)
  }
  let (body, term) = self.parse_list()
  if term.is_empty() {
    raise ParseError("unexpected EOF")
  }
  let kw = first_word(lex_action(term))
  let els : Array[Node] = if kw == "end" {
    []
  } else if kw == "else" {
    let (e, term2) = self.parse_list()
    if first_word(lex_action(term2)) != "end" {
      raise ParseError("range: expected {{end}}")
    }
    e
  } else {
    raise ParseError("range: expected {{else}} or {{end}}")
  }
  RangeNode(
    pipe,
    key_var,
    val_var,
    assign_idx < 0 || toks[assign_idx] is TAssign,
    body,
    els,
  )
}

///|
fn Parser::parse_with(
  self : Parser,
  toks : Array[Tok],
) -> Node raise TemplateError {
  let (pipe, declaration) = condition_pipeline(toks)
  let (body, term) = self.parse_list()
  if term.is_empty() {
    raise ParseError("unexpected EOF")
  }
  let kw = first_word(lex_action(term))
  let els : Array[Node] = if kw == "end" {
    []
  } else if kw == "else" {
    let (e, term2) = self.parse_list()
    if first_word(lex_action(term2)) != "end" {
      raise ParseError("with: expected {{end}}")
    }
    e
  } else {
    raise ParseError("with: expected {{else}} or {{end}}")
  }
  let node = WithNode(pipe, body, els)
  match declaration {
    Some(binding) => Scope([binding, node])
    None => node
  }
}

///|
/// Parse a node list until a `{{end}}` or `{{else}}` (returned as the terminator
/// body) or end of input (empty terminator).
fn Parser::parse_list(
  self : Parser,
) -> (Array[Node], String) raise TemplateError {
  let nodes : Array[Node] = []
  for ;; {
    if self.pos >= self.pieces.length() {
      return (nodes, "")
    }
    match self.pieces[self.pos] {
      PText(t) => {
        nodes.push(Text(t))
        self.pos += 1
      }
      PAction(body, line, column) => {
        let previous_length = nodes.length()
        let toks = lex_action(body)
        let kw = first_word(toks)
        if kw == "end" || kw == "else" {
          self.pos += 1
          return (nodes, body)
        } else if kw == "if" {
          self.pos += 1
          nodes.push(self.parse_if(toks))
        } else if kw == "range" {
          self.pos += 1
          nodes.push(self.parse_range(toks))
        } else if kw == "with" {
          self.pos += 1
          nodes.push(self.parse_with(toks))
        } else if kw == "define" {
          guard toks.length() == 2 && toks[1] is TStr(name, _) else {
            raise ParseError("unexpected define clause")
          }
          self.pos += 1
          let (body, terminator) = self.parse_list()
          guard terminator == "end" else { raise ParseError("unexpected EOF") }
          guard !self.definitions.contains(name) else {
            raise ParseError("multiple definition of template \"" + name + "\"")
          }
          self.definitions[name] = body
        } else if kw == "break" || kw == "continue" {
          guard toks.length() == 1 else {
            raise ParseError("unexpected argument to " + kw)
          }
          nodes.push(Control(kw == "break"))
          self.pos += 1
        } else if kw == "template" {
          guard toks.length() >= 2 && toks[1] is TStr(name, _) else {
            raise ParseError("unexpected template clause")
          }
          let pipe = if toks.length() == 2 {
            None
          } else {
            Some(pipeline_from(toks, 2))
          }
          nodes.push(Invoke(name, pipe))
          self.pos += 1
        } else if is_assignment(toks) {
          self.pos += 1
          nodes.push(build_assign(toks))
        } else {
          self.pos += 1
          nodes.push(Action(pipeline_from(toks, 0)))
        }
        if nodes.length() > previous_length {
          nodes[nodes.length() - 1] = Located(
            line,
            column,
            body,
            nodes[nodes.length() - 1],
          )
        }
      }
    }
  }
}

// ── Execution ────────────────────────────────────────────────────────────────

///|
priv struct Env {
  name : String
  root : Value
  funcs : Map[String, FuncFn]
  definitions : Map[String, Array[Node]]
  depth : Int32
}

///|
/// Go's notion of truth: false, zero, empty string/list/dict and nil are falsy.
fn truthy(v : Value) -> Bool {
  match v {
    Null => false
    Bool(b) => b
    Int(n) => n != 0L
    Float(f) => f != 0.0
    Str(s) => s.length() != 0
    List(xs) => xs.length() != 0
    Dict(m) => m.length() != 0
  }
}

///|
fn str_cmp(a : String, b : String) -> Int32 {
  @formatter_common.compare_text(a, b)
}

///|
fn sorted_keys(m : Map[String, Value]) -> Array[String] {
  let keys : Array[String] = []
  for k, _ in m {
    keys.push(k)
  }
  for i = 1; i < keys.length(); i = i + 1 {
    let key = keys[i]
    let mut j = i - 1
    while j >= 0 && str_cmp(keys[j], key) > 0 {
      keys[j + 1] = keys[j]
      j -= 1
    }
    keys[j + 1] = key
  }
  keys
}

///|
/// Render a `Value` to its output string, as Go's template does when a pipeline
/// value is printed. A `Null` (including a missing key) prints as the empty
/// string.
fn to_output(v : Value) -> String {
  match v {
    Null => "<no value>"
    Bool(b) => if b { "true" } else { "false" }
    Int(n) => n.to_string()
    Float(f) => f.to_string()
    Str(s) => s
    List(xs) => {
      let sb = StringBuilder()
      sb.write_string("[")
      for i = 0; i < xs.length(); i = i + 1 {
        if i > 0 {
          sb.write_string(" ")
        }
        sb.write_string(to_output(xs[i]))
      }
      sb.write_string("]")
      sb.to_string()
    }
    Dict(m) => {
      let sb = StringBuilder()
      sb.write_string("map[")
      let keys = sorted_keys(m)
      for i = 0; i < keys.length(); i = i + 1 {
        if i > 0 {
          sb.write_string(" ")
        }
        sb.write_string(keys[i])
        sb.write_string(":")
        sb.write_string(to_output(m.get(keys[i]).unwrap()))
      }
      sb.write_string("]")
      sb.to_string()
    }
  }
}

///|
fn follow(v : Value, chain : Array[String]) -> Value raise TemplateError {
  let mut cur = v
  for f in chain {
    cur = match cur {
      Dict(m) =>
        match m.get(f) {
          Some(x) => x
          None => Null
        }
      Null => Null
      _ =>
        raise ExecError("cannot access field '" + f + "' of a non-object value")
    }
  }
  cur
}

///|
fn eval_arg(
  env : Env,
  a : Arg,
  dot : Value,
  vars : Map[String, Ref[Value]],
) -> Value raise TemplateError {
  match a {
    Dot => dot
    Field(chain) => follow(dot, chain)
    Var(name, chain) => {
      let base = if name == "" {
        env.root
      } else {
        match vars.get(name) {
          Some(v) => v.val
          None => raise ExecError("undefined variable $" + name)
        }
      }
      follow(base, chain)
    }
    StrLit(s) => Str(s)
    IntLit(n) => Int(n)
    FloatLit(f) => Float(f)
    BoolLit(b) => Bool(b)
    NilLit => Null
    Sub(cmds) => eval_pipeline(env, cmds, dot, vars)
  }
}

///|
fn eval_command(
  env : Env,
  cmd : Command,
  dot : Value,
  vars : Map[String, Ref[Value]],
  piped : Value?,
) -> Value raise TemplateError {
  if cmd.fn_ is Some("and" | "or" as name) {
    guard !cmd.args.is_empty() || piped is Some(_) else {
      raise ExecError(name + ": needs at least one argument")
    }
    let mut last = Null
    for argument in cmd.args {
      last = eval_arg(env, argument, dot, vars)
      if (name == "and" && !truthy(last)) || (name == "or" && truthy(last)) {
        return last
      }
    }
    return piped.unwrap_or(last)
  }
  let args : Array[Value] = []
  for a in cmd.args {
    args.push(eval_arg(env, a, dot, vars))
  }
  match cmd.fn_ {
    Some(name) => {
      match piped {
        Some(p) => args.push(p)
        None => ()
      }
      match env.funcs.get(name) {
        Some(f) =>
          f(args) catch {
            ExecError(message) =>
              raise CommandError(
                cmd.offset,
                command_text(cmd),
                "error calling " + name + ": " + message,
              )
            error => raise error
          }
        None => raise ExecError("function '" + name + "' is not defined")
      }
    }
    None => {
      match piped {
        Some(_) => raise ExecError("cannot pipe a value into a non-function")
        None => ()
      }
      if args.length() != 1 {
        raise ExecError("value command must have exactly one argument")
      }
      args[0]
    }
  }
}

///|
fn eval_pipeline(
  env : Env,
  cmds : Array[Command],
  dot : Value,
  vars : Map[String, Ref[Value]],
) -> Value raise TemplateError {
  let mut acc : Value? = None
  for cmd in cmds {
    acc = Some(eval_command(env, cmd, dot, vars, acc))
  }
  match acc {
    Some(v) => v
    None => raise ExecError("empty pipeline")
  }
}

///|
fn render_nodes(
  env : Env,
  nodes : Array[Node],
  dot : Value,
  vars : Map[String, Ref[Value]],
  sb : StringBuilder,
) -> Unit raise TemplateError {
  for node in nodes {
    match node {
      Located(line, column, context, node) =>
        render_nodes(env, [node], dot, vars, sb) catch {
          CommandError(offset, command, message) => {
            let lines = context[:offset].split("\n").collect()
            let diagnostic_line = line + lines.length() - 1
            let diagnostic_column = (if lines.length() == 1 {
                column
              } else {
                0
              }) +
              @utf8.encode(lines.last().unwrap()).length()
            raise LocatedExec(
              "template: " +
              env.name +
              ":" +
              diagnostic_line.to_string() +
              ":" +
              diagnostic_column.to_string() +
              ": executing " +
              Json(env.name).stringify() +
              " at <" +
              command +
              ">: " +
              message,
            )
          }
          ExecError(message) =>
            raise LocatedExec(
              "template: " +
              env.name +
              ":" +
              line.to_string() +
              ":" +
              column.to_string() +
              ": executing " +
              Json(env.name).stringify() +
              " at <" +
              context +
              ">: " +
              message,
            )
          error => raise error
        }
      Scope(nodes) => render_nodes(env, nodes, dot, vars.copy(), sb)
      Control(stop) => raise LoopControl(stop)
      Text(t) => sb.write_string(t)
      Action(cmds) =>
        sb.write_string(to_output(eval_pipeline(env, cmds, dot, vars)))
      Assign(name, is_declaration, cmds) => {
        let value = eval_pipeline(env, cmds, dot, vars)
        if is_declaration {
          vars[name] = Ref(value)
        } else {
          guard vars.get(name) is Some(existing) else {
            raise ExecError("undefined variable $" + name)
          }
          existing.val = value
        }
      }
      Invoke(name, pipe) => {
        guard env.definitions.get(name) is Some(body) else {
          raise ExecError("template \"" + name + "\" not defined")
        }
        guard env.depth < 1000 else {
          raise ExecError("template recursion limit reached")
        }
        let value = match pipe {
          Some(pipe) => eval_pipeline(env, pipe, dot, vars)
          None => Null
        }
        let child : Env = { ..env, name, root: value, depth: env.depth + 1, }
        render_nodes(child, body, value, Map([]), sb)
      }
      IfNode(cmds, then_nodes, else_nodes) => {
        let v = eval_pipeline(env, cmds, dot, vars)
        let child = vars.copy()
        if truthy(v) {
          render_nodes(env, then_nodes, dot, child, sb)
        } else {
          render_nodes(env, else_nodes, dot, child, sb)
        }
      }
      WithNode(cmds, body, else_nodes) => {
        let v = eval_pipeline(env, cmds, dot, vars)
        let child = vars.copy()
        if truthy(v) {
          render_nodes(env, body, v, child, sb)
        } else {
          render_nodes(env, else_nodes, dot, child, sb)
        }
      }
      RangeNode(cmds, key_var, val_var, declaration, body, else_nodes) => {
        let v = eval_pipeline(env, cmds, dot, vars)
        let scope = vars.copy()
        for name in [key_var, val_var] {
          if name is Some(name) {
            bind_range(scope, name, v, declaration)
          }
        }
        match v {
          List(xs) =>
            if xs.length() == 0 {
              render_nodes(env, else_nodes, dot, scope, sb)
            } else {
              for i = 0; i < xs.length(); i = i + 1 {
                let child = scope.copy()
                match key_var {
                  Some(k) =>
                    bind_range(child, k, Int(i.to_int64()), declaration)
                  None => ()
                }
                match val_var {
                  Some(nm) => bind_range(child, nm, xs[i], declaration)
                  None => ()
                }
                render_nodes(env, body, xs[i], child, sb) catch {
                  LoopControl(stop) => if stop { break }
                  error => raise error
                }
              }
            }
          Dict(m) => {
            let keys = sorted_keys(m)
            if keys.length() == 0 {
              render_nodes(env, else_nodes, dot, scope, sb)
            } else {
              for key in keys {
                let value = m.get(key).unwrap()
                let child = scope.copy()
                match key_var {
                  Some(k) => bind_range(child, k, Str(key), declaration)
                  None => ()
                }
                match val_var {
                  Some(nm) => bind_range(child, nm, value, declaration)
                  None => ()
                }
                render_nodes(env, body, value, child, sb) catch {
                  LoopControl(stop) => if stop { break }
                  error => raise error
                }
              }
            }
          }
          Null => render_nodes(env, else_nodes, dot, scope, sb)
          _ =>
            raise ExecError("range: cannot iterate over a non-list/dict value")
        }
      }
    }
  }
}

///|
fn bind_range(
  vars : Map[String, Ref[Value]],
  name : String,
  value : Value,
  declaration : Bool,
) -> Unit raise TemplateError {
  if declaration {
    vars[name] = Ref(value)
  } else {
    guard vars.get(name) is Some(binding) else {
      raise ExecError("undefined variable $" + name)
    }
    binding.val = value
  }
}

// ── Pipeline function library ────────────────────────────────────────────────

///|
fn arg_at(
  xs : Array[Value],
  i : Int32,
  name : String,
) -> Value raise TemplateError {
  if i >= xs.length() {
    raise ExecError(name + ": missing argument")
  }
  xs[i]
}

///|
fn ends_with(s : String, suf : String) -> Bool {
  let sn = s.length()
  let fn_ = suf.length()
  if sn < fn_ {
    return false
  }
  for i = 0; i < fn_; i = i + 1 {
    if s[sn - fn_ + i] != suf[i] {
      return false
    }
  }
  true
}

///|
fn str_contains(hay : String, needle : String) -> Bool {
  let hn = hay.length()
  let nn = needle.length()
  if nn == 0 {
    return true
  }
  for i = 0; i + nn <= hn; i = i + 1 {
    let mut ok = true
    for j = 0; j < nn; j = j + 1 {
      if hay[i + j] != needle[j] {
        ok = false
        break
      }
    }
    if ok {
      return true
    }
  }
  false
}

///|
fn str_replace(s : String, old : String, new_ : String) -> String {
  if old.length() == 0 {
    return s
  }
  let sb = StringBuilder()
  let sn = s.length()
  let on = old.length()
  let mut i = 0
  while i < sn {
    if i + on <= sn {
      let mut ok = true
      for j = 0; j < on; j = j + 1 {
        if s[i + j] != old[j] {
          ok = false
          break
        }
      }
      if ok {
        sb.write_string(new_)
        i += on
        continue
      }
    }
    sb.write_char(s[i].to_int().unsafe_to_char())
    i += 1
  }
  sb.to_string()
}

///|
fn join_strings(parts : Array[String], sep : String) -> String {
  let sb = StringBuilder()
  for i = 0; i < parts.length(); i = i + 1 {
    if i > 0 {
      sb.write_string(sep)
    }
    sb.write_string(parts[i])
  }
  sb.to_string()
}

///|
fn title_case(s : String) -> String {
  let words = split_char(s, ' ')
  let out : Array[String] = []
  for w in words {
    if w.length() == 0 {
      out.push(w)
    } else {
      out.push(w[0:1].to_owned().to_upper() + w[1:].to_owned().to_lower())
    }
  }
  join_strings(out, " ")
}

///|
fn val_num(v : Value) -> Double? {
  match v {
    Int(n) => Some(n.to_double())
    Float(f) => Some(f)
    _ => None
  }
}

///|
fn val_eq(a : Value, b : Value) -> Bool {
  match (a, b) {
    (Null, Null) => true
    (Bool(x), Bool(y)) => x == y
    (Str(x), Str(y)) => x == y
    (Int(x), Int(y)) => x == y
    (Float(x), Float(y)) => x == y
    (Int(x), Float(y)) => x.to_double() == y
    (Float(x), Int(y)) => x == y.to_double()
    _ => false
  }
}

///|
fn val_cmp(a : Value, b : Value) -> Int32 raise TemplateError {
  match (a, b) {
    (Str(x), Str(y)) => str_cmp(x, y)
    _ =>
      match (val_num(a), val_num(b)) {
        (Some(x), Some(y)) => if x < y { -1 } else if x > y { 1 } else { 0 }
        _ =>
          raise ExecError(
            "comparison requires two numbers or two strings of the same kind",
          )
      }
  }
}

///|
fn sprintf(fmt : String, args : Array[Value], start : Int32) -> String {
  go_printf(fmt, args, start)
}

///|
/// The default function library: string helpers (`upper`, `lower`, `title`,
/// `trim`, `trimPrefix`, `trimSuffix`, `hasPrefix`, `hasSuffix`, `contains`,
/// `replace`), comparisons (`eq`, `ne`, `lt`, `le`, `gt`, `ge`), logic (`and`,
/// `or`, `not`), and `len`, `index`, `default`, `printf`, `print`, `println`.
/// String helpers put the operated-on value last so `{{.Name | trimPrefix "Get"}}`
/// pipelines read naturally.
fn default_funcs() -> Map[String, FuncFn] {
  let m : Map[String, FuncFn] = Map([])
  m["upper"] = xs => Str(to_output(arg_at(xs, 0, "upper")).to_upper())
  m["lower"] = xs => Str(to_output(arg_at(xs, 0, "lower")).to_lower())
  m["title"] = xs => Str(title_case(to_output(arg_at(xs, 0, "title"))))
  m["trim"] = xs => Str(trim(to_output(arg_at(xs, 0, "trim"))))
  m["trimPrefix"] = xs => {
    let prefix = to_output(arg_at(xs, 0, "trimPrefix"))
    let s = to_output(arg_at(xs, 1, "trimPrefix"))
    Str(if starts_with(s, prefix) { s[prefix.length():].to_owned() } else { s })
  }
  m["trimSuffix"] = xs => {
    let suffix = to_output(arg_at(xs, 0, "trimSuffix"))
    let s = to_output(arg_at(xs, 1, "trimSuffix"))
    Str(
      if ends_with(s, suffix) {
        s[0:s.length() - suffix.length()].to_owned()
      } else {
        s
      },
    )
  }
  m["hasPrefix"] = xs => {
    Bool(
      starts_with(
        to_output(arg_at(xs, 1, "hasPrefix")),
        to_output(arg_at(xs, 0, "hasPrefix")),
      ),
    )
  }
  m["hasSuffix"] = xs => {
    Bool(
      ends_with(
        to_output(arg_at(xs, 1, "hasSuffix")),
        to_output(arg_at(xs, 0, "hasSuffix")),
      ),
    )
  }
  m["contains"] = xs => {
    Bool(
      str_contains(
        to_output(arg_at(xs, 1, "contains")),
        to_output(arg_at(xs, 0, "contains")),
      ),
    )
  }
  m["replace"] = xs => {
    Str(
      str_replace(
        to_output(arg_at(xs, 2, "replace")),
        to_output(arg_at(xs, 0, "replace")),
        to_output(arg_at(xs, 1, "replace")),
      ),
    )
  }
  m["eq"] = xs => {
    if xs.length() < 2 {
      raise ExecError("eq: needs at least two arguments")
    }
    let a = xs[0]
    let mut found = false
    for i = 1; i < xs.length(); i = i + 1 {
      if val_eq(a, xs[i]) {
        found = true
      }
    }
    Bool(found)
  }
  m["ne"] = xs => Bool(!val_eq(arg_at(xs, 0, "ne"), arg_at(xs, 1, "ne")))
  m["lt"] = xs => Bool(val_cmp(arg_at(xs, 0, "lt"), arg_at(xs, 1, "lt")) < 0)
  m["le"] = xs => Bool(val_cmp(arg_at(xs, 0, "le"), arg_at(xs, 1, "le")) <= 0)
  m["gt"] = xs => Bool(val_cmp(arg_at(xs, 0, "gt"), arg_at(xs, 1, "gt")) > 0)
  m["ge"] = xs => Bool(val_cmp(arg_at(xs, 0, "ge"), arg_at(xs, 1, "ge")) >= 0)
  m["and"] = xs => {
    if xs.length() == 0 {
      raise ExecError("and: needs at least one argument")
    }
    let mut result = xs[0]
    let mut done = false
    for x in xs {
      if !done {
        result = x
        if !truthy(x) {
          done = true
        }
      }
    }
    result
  }
  m["or"] = xs => {
    if xs.length() == 0 {
      raise ExecError("or: needs at least one argument")
    }
    let mut result = xs[0]
    let mut done = false
    for x in xs {
      if !done {
        result = x
        if truthy(x) {
          done = true
        }
      }
    }
    result
  }
  m["not"] = xs => Bool(!truthy(arg_at(xs, 0, "not")))
  m["len"] = xs => {
    let v = arg_at(xs, 0, "len")
    let n = match v {
      Str(s) => s.length()
      List(l) => l.length()
      Dict(d) => d.length()
      Null => 0
      _ => raise ExecError("len: value has no length")
    }
    Int(n.to_int64())
  }
  m["index"] = xs => {
    if xs.length() < 1 {
      raise ExecError("index: needs at least one argument")
    }
    let mut cur = xs[0]
    for i = 1; i < xs.length(); i = i + 1 {
      let k = xs[i]
      cur = match cur {
        List(l) =>
          match k {
            Int(n) =>
              if n >= 0L && n < l.length().to_int64() {
                l[n.to_int()]
              } else {
                raise ExecError("index out of range: " + n.to_string())
              }
            _ => raise ExecError("index: list index must be an integer")
          }
        Dict(d) =>
          match k {
            Str(s) =>
              match d.get(s) {
                Some(x) => x
                None => Null
              }
            _ => raise ExecError("index: map key must be a string")
          }
        _ => raise ExecError("can't index item of type " + go_type(cur))
      }
    }
    cur
  }
  m["default"] = xs => {
    let d = arg_at(xs, 0, "default")
    let v = arg_at(xs, 1, "default")
    if truthy(v) {
      v
    } else {
      d
    }
  }
  m["printf"] = xs => Str(sprintf(to_output(arg_at(xs, 0, "printf")), xs, 1))
  m["print"] = xs => {
    let sb = StringBuilder()
    for index, x in xs {
      if index > 0 && !(x is Str(_)) && !(xs[index - 1] is Str(_)) {
        sb.write_char(' ')
      }
      sb.write_string(to_output(x))
    }
    Str(sb.to_string())
  }
  m["println"] = xs => {
    let sb = StringBuilder()
    for index, x in xs {
      if index > 0 {
        sb.write_char(' ')
      }
      sb.write_string(to_output(x))
    }
    sb.write_string("\n")
    Str(sb.to_string())
  }
  m
}

// ── Public API ───────────────────────────────────────────────────────────────

///|
/// A parsed, reusable template — moonctl's `text/template` equivalent. Build it
/// with `Template::new`, register extra functions with `func`, parse a source
/// with `parse`, then `render` it against a `Value` any number of times. The
/// parsed node tree stays private, captured inside `renderer`.
pub struct Template {
  mut renderer : (Value, StringBuilder) -> Unit raise TemplateError
  funcs : Map[String, FuncFn]
}

///|
/// A fresh template preloaded with the default function library. Rendering before
/// `parse` yields the empty string.
pub fn Template::new() -> Template {
  { renderer: (_data, _output) => (), funcs: default_funcs(), }
}

///|
/// Register (or override) a pipeline function, returning `self` for chaining —
/// the analogue of Go's `Template.Funcs`. Register before `parse`.
pub fn Template::func(self : Template, name : String, f : FuncFn) -> Template {
  self.funcs[name] = f
  self
}

///|
/// Parse `source` into this template's node tree, returning `self` for chaining.
/// Raises `ParseError` on a syntax error (unclosed action, dangling `{{end}}`, …).
pub fn Template::parse(
  self : Template,
  source : String,
) -> Template raise TemplateError {
  let parser : Parser = { pieces: scan(source), pos: 0, definitions: Map([]), }
  let (nodes, term) = parser.parse_list()
  if term != "" {
    raise ParseError(
      "unexpected {{" + term + "}} with no matching block opener",
    )
  }
  let funcs = self.funcs
  validate_nodes(nodes, funcs)
  for definition in parser.definitions.values() {
    validate_nodes(definition, funcs)
  }
  self.renderer = (data, sb) => {
    let env : Env = {
      name: "",
      root: data,
      funcs,
      definitions: parser.definitions,
      depth: 0,
    }
    render_nodes(env, nodes, data, Map([]), sb)
  }
  self
}

///|
/// Render the template against `data`, producing the output string. Raises
/// `ExecError` on an execution fault (undefined variable/function, bad range
/// target, …).
pub fn Template::render(
  self : Template,
  data : Value,
) -> String raise TemplateError {
  let output = StringBuilder()
  (self.renderer)(data, output)
  output.to_string()
}

///|
/// Parse and render `source` against `data` in one call, with the default
/// function library.
pub fn render(source : String, data : Value) -> String raise TemplateError {
  Template::new().parse(source).render(data)
}
