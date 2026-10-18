///|
pub struct Output {
  stdout : String
  stderr : String
  exit_code : Int32
  priv bytes : Bytes?
}

///|
pub fn Output::new(
  stdout~ : String = "",
  stderr~ : String = "",
  exit_code~ : Int32 = 0,
) -> Output {
  { stdout, stderr, exit_code, bytes: None, }
}

///|
pub fn Output::from_bytes(
  stdout : Bytes,
  stderr~ : String = "",
  exit_code~ : Int32 = 0,
) -> Output {
  let text = @utf8.decode(stdout) catch { _ => stdout.to_unchecked_string() }
  { stdout: text, stderr, exit_code, bytes: Some(stdout), }
}

///|
pub fn Output::stdout_bytes(self : Output) -> Bytes {
  match self.bytes {
    Some(bytes) => bytes
    None => @utf8.encode(self.stdout)
  }
}

///|
pub fn Output::stdout(self : Output) -> String {
  self.stdout
}

///|
pub fn Output::stderr(self : Output) -> String {
  self.stderr
}

///|
pub fn Output::exit_code(self : Output) -> Int32 {
  self.exit_code
}

///|
pub fn success(stdout~ : String, stderr~ : String = "") -> Output {
  Output::new(stdout~, stderr~)
}

///|
pub fn failure(message~ : String, exit_code~ : Int32 = 1) -> Output {
  Output::new(stderr="gh: " + message + "\n", exit_code~)
}

///|
fn status_text(status : Int32) -> String {
  match status {
    200 => "OK"
    201 => "Created"
    202 => "Accepted"
    204 => "No Content"
    206 => "Partial Content"
    301 => "Moved Permanently"
    302 => "Found"
    303 => "See Other"
    304 => "Not Modified"
    307 => "Temporary Redirect"
    308 => "Permanent Redirect"
    400 => "Bad Request"
    401 => "Unauthorized"
    403 => "Forbidden"
    404 => "Not Found"
    405 => "Method Not Allowed"
    409 => "Conflict"
    410 => "Gone"
    415 => "Unsupported Media Type"
    422 => "Unprocessable Entity"
    429 => "Too Many Requests"
    500 => "Internal Server Error"
    502 => "Bad Gateway"
    503 => "Service Unavailable"
    504 => "Gateway Timeout"
    _ => ""
  }
}

///|
fn has_nul(bytes : Bytes) -> Bool {
  for byte in bytes {
    if byte == 0 {
      return true
    }
  }
  false
}

///|
/// Strip common terminal escape sequences from text output.
fn sanitize_terminal_escapes(text : String) -> String {
  let out = StringBuilder()
  let mut mode = 0
  for ch in text {
    let code = ch.to_int()
    match mode {
      0 => if code == 27 { mode = 1 } else { out.write_char(ch) }
      1 =>
        if ch == '[' {
          mode = 2
        } else if ch == ']' {
          mode = 3
        } else {
          mode = 0
        }
      2 => if code >= 64 && code <= 126 { mode = 0 }
      3 => if code == 7 { mode = 0 } else if code == 27 { mode = 4 }
      4 => mode = 0
      _ => mode = 0
    }
  }
  out.to_string()
}

///|
fn text_for_output(text : String, allow_escape_sequences : Bool) -> String {
  if allow_escape_sequences {
    text
  } else {
    sanitize_terminal_escapes(text)
  }
}

///|
fn parse_path(path : String) -> Result[Array[String], String] {
  guard path.has_prefix(".") else {
    return Err("jq expression must start with '.'")
  }
  let source = if path.has_prefix(".") { path[1:].to_owned() } else { path }
  guard !source.is_empty() else { return Ok([]) }
  let segments : Array[String] = []
  for segment in source.split(".") {
    guard !segment.is_empty() else { return Err("malformed jq path") }
    for
      marker in [
        " ", "\t", "\n", "|", ",", "(", ")", "+", "-", "*", "/", "\\", "\"", "'",
      ] {
      guard !segment.contains(marker) else {
        return Err("unsupported jq expression")
      }
    }
    guard !segment.contains("[") && !segment.contains("]") else {
      return Err("unsupported jq path")
    }
    guard !segment.contains("{") && !segment.contains("}") else {
      return Err("unsupported jq path")
    }
    segments.push(segment.to_owned())
  }
  Ok(segments)
}

///|
/// Return all values selected by the path subset used by gh's common jq
/// filters.  It supports `.field`, `.field.nested`, `.items[]`, `.[].name`,
/// and numeric array indexes while preserving missing values as `null`.
fn jq_path_values(
  value : Json,
  expression : String,
) -> Result[Array[Json], String] {
  guard expression.has_prefix(".") else {
    return Err("jq expression must start with '.'")
  }
  let rest = expression[1:].to_owned()
  if rest.is_empty() {
    return Ok([value])
  }
  let current : Array[Json] = [value]
  let mut cursor = 0
  let mut values = current
  while cursor < rest.length() {
    if rest[cursor] == '.' {
      cursor += 1
      guard cursor < rest.length() else { return Err("malformed jq path") }
    }
    if rest[cursor] == '[' {
      guard cursor + 1 < rest.length() else { return Err("malformed jq path") }
      if rest[cursor + 1] == ']' {
        cursor += 2
        let next : Array[Json] = []
        for item in values {
          match item {
            Array(items) =>
              for child in items {
                next.push(child)
              }
            _ => ()
          }
        }
        values = next
        continue
      }
      let start = cursor + 1
      let mut end = start
      while end < rest.length() && rest[end] != ']' {
        end += 1
      }
      guard end < rest.length() else { return Err("malformed jq index") }
      let next : Array[Json] = []
      let selector = rest[start:end].to_owned()
      if selector.has_prefix("\"") && selector.has_suffix("\"") {
        let key = match filter_literal(selector) {
          Ok(String(key)) => key
          _ => return Err("invalid jq object key")
        }
        for item in values {
          match item {
            Object(fields) => next.push(fields.get(key).unwrap_or(Json::null()))
            _ => next.push(Json::null())
          }
        }
      } else {
        let index = @string.parse_int(selector) catch {
          _ => return Err("invalid jq index")
        }
        guard index >= 0 else { return Err("invalid jq index") }
        for item in values {
          match item {
            Array(items) => next.push(items.get(index).unwrap_or(Json::null()))
            _ => next.push(Json::null())
          }
        }
      }
      values = next
      cursor = end + 1
      continue
    }
    // jq's optional operator after an iterator (`.items[]?`) suppresses the
    // type error for non-arrays. The path evaluator already models that
    // behavior by yielding no values for a non-array, so consume the marker
    // here and continue parsing the following selector.
    if rest[cursor] == '?' {
      cursor += 1
      continue
    }
    let start = cursor
    while cursor < rest.length() && rest[cursor] != '.' && rest[cursor] != '[' {
      guard rest[cursor].to_int() > 32 else {
        return Err("unsupported jq expression")
      }
      cursor += 1
    }
    guard cursor > start else { return Err("malformed jq path") }
    let mut name = rest[start:cursor].to_owned()
    // Optional object lookup (`.missing?`) has the same null result as a
    // normal lookup in our bounded evaluator, but the `?` must not become
    // part of the field name.
    if name.has_suffix("?") {
      name = name.strip_suffix("?").unwrap_or(name).to_owned()
      guard !name.is_empty() else { return Err("malformed jq path") }
    }
    let next : Array[Json] = []
    for item in values {
      match item {
        Object(fields) => next.push(fields.get(name).unwrap_or(Json::null()))
        _ => next.push(Json::null())
      }
    }
    values = next
  }
  Ok(values)
}

///|
fn lookup_json(value : Json, path : Array[String]) -> Json {
  let mut current = value
  for segment in path {
    current = match current {
      Object(fields) => fields.get(segment).unwrap_or(Json::null())
      _ => Json::null()
    }
  }
  current
}

///|
fn json_to_filter_text(value : Json) -> String {
  match value {
    String(text) => text
    Null => "null"
    other => other.stringify()
  }
}

///|
/// Split a filter while respecting jq strings and nested constructors.  A
/// plain String::split is not sufficient for expressions such as
/// `map(select(.state == "open")) | .[].name`.
fn split_filter_parts(
  source : String,
  delimiter : Char,
) -> Result[Array[String], String] {
  let parts : Array[String] = []
  let mut start = 0
  let mut cursor = 0
  let mut quote : Char? = None
  let mut escaped = false
  let mut parentheses = 0
  let mut brackets = 0
  let mut braces = 0
  while cursor < source.length() {
    let ch = source.get_char(cursor).unwrap_or('\u{0}')
    match quote {
      Some(active) =>
        if escaped {
          escaped = false
        } else if ch == '\\' {
          escaped = true
        } else if ch == active {
          quote = None
        }
      None =>
        if ch == '"' || ch == '\'' {
          quote = Some(ch)
        } else if ch == '(' {
          parentheses += 1
        } else if ch == ')' {
          parentheses -= 1
          guard parentheses >= 0 else { return Err("malformed filter") }
        } else if ch == '[' {
          brackets += 1
        } else if ch == ']' {
          brackets -= 1
          guard brackets >= 0 else { return Err("malformed filter") }
        } else if ch == '{' {
          braces += 1
        } else if ch == '}' {
          braces -= 1
          guard braces >= 0 else { return Err("malformed filter") }
        } else if ch == delimiter &&
          parentheses == 0 &&
          brackets == 0 &&
          braces == 0 {
          parts.push(source[start:cursor].to_owned())
          start = cursor + 1
        }
    }
    cursor += 1
  }
  guard quote is None && parentheses == 0 && brackets == 0 && braces == 0 else {
    return Err("malformed filter")
  }
  parts.push(source[start:].to_owned())
  Ok(parts)
}

///|
/// Find an operator at the top level of a jq expression. Operators inside
/// strings or nested constructors must not split the filter.
fn split_filter_operator(
  source : String,
  operator : String,
) -> (String, String)? {
  let mut cursor = 0
  let mut quote : Char? = None
  let mut escaped = false
  let mut parentheses = 0
  let mut brackets = 0
  let mut braces = 0
  while cursor < source.length() {
    let ch = source.get_char(cursor).unwrap_or('\u{0}')
    match quote {
      Some(active) =>
        if escaped {
          escaped = false
        } else if ch == '\\' {
          escaped = true
        } else if ch == active {
          quote = None
        }
      None =>
        if ch == '"' || ch == '\'' {
          quote = Some(ch)
        } else if ch == '(' {
          parentheses += 1
        } else if ch == ')' {
          parentheses -= 1
        } else if ch == '[' {
          brackets += 1
        } else if ch == ']' {
          brackets -= 1
        } else if ch == '{' {
          braces += 1
        } else if ch == '}' {
          braces -= 1
        } else if parentheses == 0 && brackets == 0 && braces == 0 {
          let end = cursor + operator.length()
          if end <= source.length() && source[cursor:end] == operator {
            let before_ok = cursor == 0 ||
              source.get_char(cursor - 1).unwrap_or(' ').to_int() <= 32
            let after_ok = end == source.length() ||
              source.get_char(end).unwrap_or(' ').to_int() <= 32
            if before_ok && after_ok {
              return Some((source[:cursor].to_owned(), source[end:].to_owned()))
            }
          }
        }
    }
    cursor += 1
  }
  None
}

///|
fn filter_literal(text : String) -> Result[Json, String] {
  let value : Json = @json.parse(text) catch {
    _ => return Err("invalid JSON literal")
  }
  Ok(value)
}

///|
fn json_compare(left : Json, right : Json, operator : String) -> Bool {
  match operator {
    "==" => Json::equal(left, right)
    "!=" => !Json::equal(left, right)
    ">" =>
      match (left, right) {
        (Number(a, ..), Number(b, ..)) => a > b
        (String(a), String(b)) => a > b
        _ => false
      }
    ">=" =>
      match (left, right) {
        (Number(a, ..), Number(b, ..)) => a >= b
        (String(a), String(b)) => a >= b
        _ => false
      }
    "<" =>
      match (left, right) {
        (Number(a, ..), Number(b, ..)) => a < b
        (String(a), String(b)) => a < b
        _ => false
      }
    "<=" =>
      match (left, right) {
        (Number(a, ..), Number(b, ..)) => a <= b
        (String(a), String(b)) => a <= b
        _ => false
      }
    _ => false
  }
}

///|
fn jq_truthy(value : Json) -> Bool {
  match value {
    Null | False => false
    _ => true
  }
}

///|
fn jq_first(values : Array[Json]) -> Json {
  values.get(0).unwrap_or(Json::null())
}

///|
fn jq_predicate(value : Json, expression : String) -> Result[Bool, String] {
  let expression = expression.trim().to_owned()
  if expression.has_prefix("not ") {
    return jq_predicate(value, expression[4:].trim().to_owned()).map(v => !v)
  }
  // `and` binds more tightly than `or`; recurse before looking for comparison
  // operators so each side can contain its own predicate expression.
  match split_filter_operator(expression, "or") {
    Some((left, right)) => {
      let lhs = jq_predicate(value, left)
      let rhs = jq_predicate(value, right)
      return match (lhs, rhs) {
        (Ok(lhs), Ok(rhs)) => Ok(lhs || rhs)
        (Err(error), _) => Err(error)
        (_, Err(error)) => Err(error)
      }
    }
    None => ()
  }
  match split_filter_operator(expression, "and") {
    Some((left, right)) => {
      let lhs = jq_predicate(value, left)
      let rhs = jq_predicate(value, right)
      return match (lhs, rhs) {
        (Ok(lhs), Ok(rhs)) => Ok(lhs && rhs)
        (Err(error), _) => Err(error)
        (_, Err(error)) => Err(error)
      }
    }
    None => ()
  }
  for operator in ["==", "!=", ">=", "<=", ">", "<"] {
    match split_filter_operator(expression, operator) {
      Some((left, right)) => {
        let lhs_values = match jq_eval(value, left.trim().to_owned()) {
          Ok(values) => values
          Err(error) => return Err(error)
        }
        let lhs = jq_first(lhs_values)
        let rhs = match filter_literal(right.trim().to_owned()) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        return Ok(json_compare(lhs, rhs, operator))
      }
      None => ()
    }
  }
  jq_eval(value, expression).map(values => jq_truthy(jq_first(values)))
}

///|
fn jq_join_value(value : Json, separator : String) -> String {
  match value {
    Array(items) => items.map(json_to_filter_text).join(separator)
    _ => json_to_filter_text(value)
  }
}

///|
fn jq_csv_value(value : Json) -> String {
  let text = json_to_filter_text(value)
  if text.contains(",") ||
    text.contains("\"") ||
    text.contains("\n") ||
    text.contains("\r") {
    "\"" + text.replace(old="\"", new="\"\"") + "\""
  } else {
    text
  }
}

///|
fn jq_number(value : Json) -> Double? {
  match value {
    Number(number, ..) => Some(number)
    _ => None
  }
}

///|
fn jq_number_literal(value : Json, label : String) -> Result[Double, String] {
  match jq_number(value) {
    Some(number) => Ok(number)
    None => Err(label + " must be a number")
  }
}

///|
fn jq_eval_arguments(
  value : Json,
  source : String,
  delimiter : Char,
) -> Result[Array[Json], String] {
  let parts = match split_filter_parts(source, delimiter) {
    Ok(parts) => parts
    Err(error) => return Err(error)
  }
  let output : Array[Json] = []
  for part in parts {
    let part = part.trim().to_owned()
    guard !part.is_empty() else { return Err("malformed jq arguments") }
    let selected = match jq_eval(value, part) {
      Ok(items) => items
      Err(error) => return Err(error)
    }
    output.push(jq_first(selected))
  }
  Ok(output)
}

///|
fn jq_flatten_once(items : Array[Json]) -> Array[Json] {
  let output : Array[Json] = []
  for item in items {
    match item {
      Array(children) => output.append(children)
      _ => output.push(item)
    }
  }
  output
}

///|
fn jq_uri_escape(value : String) -> String {
  let out = StringBuilder()
  let hex = "0123456789ABCDEF"
  for byte in @utf8.encode(value) {
    let safe = byte
      is (b'a'..<=b'z'
      | b'A'..<=b'Z'
      | b'0'..<=b'9'
      | b'-'
      | b'_'
      | b'.'
      | b'~')
    if safe {
      out.write_char(byte.to_int().unsafe_to_char())
    } else {
      out.write_char('%')
      out.write_char(hex.get_char(byte.to_int() / 16).unwrap())
      out.write_char(hex.get_char(byte.to_int() % 16).unwrap())
    }
  }
  out.to_string()
}

///|
fn jq_string_value(value : Json, label : String) -> Result[String, String] {
  match value {
    String(text) => Ok(text)
    _ => Err(label + " must be a string")
  }
}

///|
fn jq_contains(haystack : Json, needle : Json) -> Bool {
  match (haystack, needle) {
    (String(left), String(right)) => left.contains(right)
    (Array(items), value) =>
      items.any(item => jq_contains(item, value) || Json::equal(item, value))
    (Object(left), Object(right)) => {
      for key, expected in right {
        match left.get(key) {
          Some(actual) if jq_contains(actual, expected) ||
            Json::equal(actual, expected) => ()
          _ => return false
        }
      }
      true
    }
    _ => Json::equal(haystack, needle)
  }
}

///|
fn jq_order_key(value : Json) -> String {
  // JSON's canonical representation gives deterministic ordering for the
  // heterogeneous values commonly returned by GitHub APIs. Strings sort by
  // their text, while numbers and booleans retain a stable lexical fallback.
  value.stringify()
}

///|
fn jq_arithmetic(
  value : Json,
  left : String,
  right : String,
  operator : Char,
) -> Result[Array[Json], String] {
  let lhs = match jq_eval(value, left.trim().to_owned()) {
    Ok(values) => jq_first(values)
    Err(error) => return Err(error)
  }
  let rhs = match jq_eval(value, right.trim().to_owned()) {
    Ok(values) => jq_first(values)
    Err(error) => return Err(error)
  }
  match operator {
    '+' =>
      match (lhs, rhs) {
        (Number(left, ..), Number(right, ..)) =>
          Ok([Json::number(left + right)])
        (String(left), String(right)) => Ok([Json::string(left + right)])
        (Array(left), Array(right)) => {
          let output = left
          output.append(right)
          Ok([Json::array(output)])
        }
        _ => Err("cannot add values")
      }
    '-' | '*' | '/' => {
      let left = match jq_number(lhs) {
        Some(number) => number
        None => return Err("arithmetic operands must be numbers")
      }
      let right = match jq_number(rhs) {
        Some(number) => number
        None => return Err("arithmetic operands must be numbers")
      }
      if operator == '/' && right == 0.0 {
        return Err("division by zero")
      }
      let result = match operator {
        '-' => left - right
        '*' => left * right
        _ => left / right
      }
      Ok([Json::number(result)])
    }
    _ => Err("unsupported arithmetic operator")
  }
}

///|
fn jq_eval(value : Json, expression : String) -> Result[Array[Json], String] {
  let expression = expression.trim().to_owned()
  guard !expression.is_empty() else { return Err("empty jq expression") }
  // Handle select before top-level logical operators.  The predicate inside
  // `select(...)` may itself contain `and`/`or`; matching those tokens here
  // would incorrectly split the function call at its nested parentheses.
  if expression.has_prefix("select(") && expression.has_suffix(")") {
    let inner = expression[7:expression.length() - 1].trim().to_owned()
    let matches = match jq_predicate(value, inner) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    return if matches { Ok([value]) } else { Ok([]) }
  }
  match split_filter_operator(expression, "or") {
    Some((left, right)) => {
      let left = match jq_predicate(value, left) {
        Ok(items) => items
        Err(error) => return Err(error)
      }
      let right = match jq_predicate(value, right) {
        Ok(items) => items
        Err(error) => return Err(error)
      }
      return Ok([Json::boolean(left || right)])
    }
    None => ()
  }
  match split_filter_operator(expression, "and") {
    Some((left, right)) => {
      let left = match jq_predicate(value, left) {
        Ok(items) => items
        Err(error) => return Err(error)
      }
      let right = match jq_predicate(value, right) {
        Ok(items) => items
        Err(error) => return Err(error)
      }
      return Ok([Json::boolean(left && right)])
    }
    None => ()
  }
  for operator in ['+', '-', '*', '/'] {
    let parts = match split_filter_parts(expression, operator) {
      Ok(parts) => parts
      Err(_) => []
    }
    if parts.length() == 2 &&
      !parts[0].trim().is_empty() &&
      !parts[1].trim().is_empty() {
      return jq_arithmetic(value, parts[0], parts[1], operator)
    }
  }
  if expression == "not" {
    return Ok([Json::boolean(!jq_truthy(value))])
  }
  if expression.has_prefix("range(") && expression.has_suffix(")") {
    let arguments = match
      jq_eval_arguments(
        value,
        expression[6:expression.length() - 1].to_owned(),
        ';',
      ) {
      Ok(arguments) => arguments
      Err(error) => return Err(error)
    }
    guard arguments.length() >= 1 && arguments.length() <= 3 else {
      return Err("range expects one to three arguments")
    }
    let mut start = 0.0
    let mut end_index = 0
    if arguments.length() == 1 {
      end_index = 0
    } else {
      start = match jq_number_literal(arguments[0], "range start") {
        Ok(number) => number
        Err(error) => return Err(error)
      }
      end_index = 1
    }
    let end = match jq_number_literal(arguments[end_index], "range end") {
      Ok(number) => number
      Err(error) => return Err(error)
    }
    let step = if arguments.length() == 3 {
      match jq_number_literal(arguments[2], "range step") {
        Ok(number) if number != 0.0 => number
        Ok(_) => return Err("range step cannot be zero")
        Err(error) => return Err(error)
      }
    } else {
      1.0
    }
    let output : Array[Json] = []
    let mut current = start
    if step > 0.0 {
      while current < end {
        output.push(Json::number(current))
        current += step
      }
    } else {
      while current > end {
        output.push(Json::number(current))
        current += step
      }
    }
    return Ok(output)
  }
  if expression.has_prefix("has(") && expression.has_suffix(")") {
    let arguments = match
      jq_eval_arguments(
        value,
        expression[4:expression.length() - 1].to_owned(),
        ',',
      ) {
      Ok(arguments) if arguments.length() == 1 => arguments
      Ok(_) => return Err("has expects one argument")
      Err(error) => return Err(error)
    }
    return Ok([
      Json::boolean(
        match (value, arguments[0]) {
          (Object(fields), String(key)) => fields.contains(key)
          (Array(items), Number(index, ..)) =>
            index >= 0.0 &&
            index < items.length().to_double() &&
            index == index.floor()
          _ => false
        },
      ),
    ])
  }
  if expression.has_prefix("contains(") && expression.has_suffix(")") {
    let arguments = match
      jq_eval_arguments(
        value,
        expression[9:expression.length() - 1].to_owned(),
        ',',
      ) {
      Ok(arguments) if arguments.length() == 1 => arguments
      Ok(_) => return Err("contains expects one argument")
      Err(error) => return Err(error)
    }
    return Ok([Json::boolean(jq_contains(value, arguments[0]))])
  }
  if (
      expression.has_prefix("startswith(") || expression.has_prefix("endswith(")
    ) &&
    expression.has_suffix(")") {
    let starts = expression.has_prefix("startswith(")
    let offset = if starts { 11 } else { 9 }
    let arguments = match
      jq_eval_arguments(
        value,
        expression[offset:expression.length() - 1].to_owned(),
        ',',
      ) {
      Ok(arguments) if arguments.length() == 1 => arguments
      Ok(_) => return Err("string predicate expects one argument")
      Err(error) => return Err(error)
    }
    let left = match jq_string_value(value, "string predicate input") {
      Ok(text) => text
      Err(error) => return Err(error)
    }
    let right = match
      jq_string_value(arguments[0], "string predicate argument") {
      Ok(text) => text
      Err(error) => return Err(error)
    }
    return Ok([
      Json::boolean(
        if starts {
          left.has_prefix(right)
        } else {
          left.has_suffix(right)
        },
      ),
    ])
  }
  if expression == "ascii_downcase" || expression == "ascii_upcase" {
    let text = match jq_string_value(value, expression) {
      Ok(text) => text
      Err(error) => return Err(error)
    }
    return Ok([
      Json::string(
        if expression == "ascii_downcase" {
          text.to_lower()
        } else {
          text.to_upper()
        },
      ),
    ])
  }
  if expression == "add" {
    return match value {
      Array(items) if items.is_empty() => Ok([Json::null()])
      Array(items) =>
        match items[0] {
          Number(_, ..) => {
            let mut total = 0.0
            for item in items {
              match item {
                Number(number, ..) => total += number
                _ => return Err("add expects compatible values")
              }
            }
            Ok([Json::number(total)])
          }
          String(_) => {
            let text = StringBuilder()
            for item in items {
              match item {
                String(value) => text.write_string(value)
                _ => return Err("add expects compatible values")
              }
            }
            Ok([Json::string(text.to_string())])
          }
          Array(_) => {
            let output : Array[Json] = []
            for item in items {
              match item {
                Array(children) => output.append(children)
                _ => return Err("add expects compatible values")
              }
            }
            Ok([Json::array(output)])
          }
          _ => Err("add expects compatible values")
        }
      _ => Ok([Json::null()])
    }
  }
  if expression == "flatten" ||
    (expression.has_prefix("flatten(") && expression.has_suffix(")")) {
    let depth = if expression == "flatten" {
      None
    } else {
      let arguments = match
        jq_eval_arguments(
          value,
          expression[8:expression.length() - 1].to_owned(),
          ',',
        ) {
        Ok(arguments) if arguments.length() == 1 => arguments
        Ok(_) => return Err("flatten expects one argument")
        Err(error) => return Err(error)
      }
      match jq_number_literal(arguments[0], "flatten depth") {
        Ok(number) if number >= 0.0 => Some(number.to_int())
        Ok(_) => return Err("flatten depth must be nonnegative")
        Err(error) => return Err(error)
      }
    }
    return match value {
      Array(items) => {
        let mut output = items
        match depth {
          None =>
            while output.any(item => item is Array(_)) {
              output = jq_flatten_once(output)
            }
          Some(depth) => {
            let mut remaining = depth
            while remaining > 0 {
              output = jq_flatten_once(output)
              remaining -= 1
            }
          }
        }
        Ok([Json::array(output)])
      }
      _ => Ok([Json::null()])
    }
  }
  if expression == "sort" || expression == "unique" {
    return match value {
      Array(items) => {
        let output = items.copy()
        output.sort_by((left, right) => {
          jq_order_key(left).compare(jq_order_key(right))
        })
        if expression == "sort" {
          return Ok([Json::array(output)])
        }
        let unique : Array[Json] = []
        for item in output {
          if unique.last() is None || !Json::equal(unique.last().unwrap(), item) {
            unique.push(item)
          }
        }
        Ok([Json::array(unique)])
      }
      _ => Ok([Json::null()])
    }
  }
  if expression.has_prefix("map_values(") && expression.has_suffix(")") {
    let inner = expression[11:expression.length() - 1].to_owned()
    return match value {
      Object(fields) => {
        let output : Map[String, Json] = Map([])
        for key, item in fields {
          let selected = match jq_eval(item, inner) {
            Ok(selected) => selected
            Err(error) => return Err(error)
          }
          if selected.get(0) is Some(mapped) {
            output[key] = mapped
          }
        }
        Ok([Json::object(output)])
      }
      Array(items) => {
        let output : Array[Json] = []
        for item in items {
          let selected = match jq_eval(item, inner) {
            Ok(selected) => selected
            Err(error) => return Err(error)
          }
          if selected.get(0) is Some(mapped) {
            output.push(mapped)
          }
        }
        Ok([Json::array(output)])
      }
      _ => Ok([Json::null()])
    }
  }
  if expression.has_prefix("map(") && expression.has_suffix(")") {
    let inner = expression[4:expression.length() - 1].to_owned()
    match value {
      Array(items) => {
        let mapped : Array[Json] = []
        for item in items {
          match jq_eval(item, inner) {
            Ok(values) => mapped.append(values)
            Err(error) => return Err(error)
          }
        }
        Ok([Json::array(mapped)])
      }
      _ => Ok([Json::null()])
    }
  } else if expression.has_prefix("[") && expression.has_suffix("]") {
    let inner = expression[1:expression.length() - 1].trim().to_owned()
    let output : Array[Json] = []
    let parts = match split_filter_parts(inner, ',') {
      Ok(parts) => parts
      Err(error) => return Err(error)
    }
    for part in parts {
      match jq_eval(value, part) {
        Ok(values) => output.append(values)
        Err(error) => return Err(error)
      }
    }
    Ok([Json::array(output)])
  } else if expression.has_prefix("{") && expression.has_suffix("}") {
    let inner = expression[1:expression.length() - 1].trim().to_owned()
    let fields : Map[String, Json] = Map([])
    let parts = match split_filter_parts(inner, ',') {
      Ok(parts) => parts
      Err(error) => return Err(error)
    }
    for part in parts {
      let (name, child) = match part.split_once(":") {
        Some(pair) => pair
        // jq permits object shorthand, e.g. `{name, login}`. The field is
        // read from the current dot value just like `{name: .name}`.
        None => (part.trim().to_owned(), "." + part.trim().to_owned())
      }
      let raw_name = name.trim().to_owned()
      guard !raw_name.is_empty() else {
        return Err("object field cannot be empty")
      }
      let field_name = if raw_name.has_prefix("\"") && raw_name.has_suffix("\"") {
        raw_name[1:raw_name.length() - 1].to_owned()
      } else {
        raw_name
      }
      let selected = match jq_eval(value, child.trim().to_owned()) {
        Ok(values) => values
        Err(error) => return Err(error)
      }
      fields[field_name] = jq_first(selected)
    }
    Ok([Json::object(fields)])
  } else if expression == "length" {
    Ok([
      match value {
        Null => Json::number(0.0)
        Array(items) => Json::number(items.length().to_double())
        Object(fields) => Json::number(fields.length().to_double())
        String(text) => Json::number(text.length().to_double())
        _ => Json::null()
      },
    ])
  } else if expression == "type" {
    Ok([
      Json::string(
        match value {
          Null => "null"
          True | False => "boolean"
          Number(_) => "number"
          String(_) => "string"
          Array(_) => "array"
          Object(_) => "object"
        },
      ),
    ])
  } else if expression == "keys" || expression == "keys_unsorted" {
    match value {
      Object(fields) => {
        let keys : Array[Json] = []
        for key, _ in fields {
          keys.push(Json::string(key))
        }
        Ok([Json::array(keys)])
      }
      Array(items) => {
        let keys : Array[Json] = []
        for index in 0..<items.length() {
          keys.push(Json::number(index.to_double()))
        }
        Ok([Json::array(keys)])
      }
      _ => Ok([Json::null()])
    }
  } else if expression == "values" {
    match value {
      Object(fields) => {
        let output : Array[Json] = []
        for _, item in fields {
          output.push(item)
        }
        Ok(output)
      }
      _ => Ok([Json::null()])
    }
  } else if expression == "to_entries" {
    match value {
      Object(fields) => {
        let output : Array[Json] = []
        for key, item in fields {
          let entry : Map[String, Json] = Map([])
          entry["key"] = Json::string(key)
          entry["value"] = item
          output.push(Json::object(entry))
        }
        Ok([Json::array(output)])
      }
      _ => Ok([Json::null()])
    }
  } else if expression == "empty" {
    Ok([])
  } else if expression.has_prefix("join(") && expression.has_suffix(")") {
    let separator_value = match
      filter_literal(expression[5:expression.length() - 1].trim().to_owned()) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    let separator = match separator_value {
      String(text) => text
      _ => return Err("join separator must be a string")
    }
    Ok([Json::string(jq_join_value(value, separator))])
  } else if expression == "@json" {
    Ok([Json::string(value.stringify())])
  } else if expression == "@text" {
    Ok([Json::string(json_to_filter_text(value))])
  } else if expression == "@uri" {
    Ok([Json::string(jq_uri_escape(json_to_filter_text(value)))])
  } else if expression == "@base64" {
    Ok([Json::string(@base64.encode(@utf8.encode(json_to_filter_text(value))))])
  } else if expression == "@base64d" {
    let decoded = @base64.decode(json_to_filter_text(value)) catch {
      _ => return Err("invalid base64 input")
    }
    let text = @utf8.decode(decoded) catch {
      _ => return Err("base64 input is not valid UTF-8")
    }
    Ok([Json::string(text)])
  } else if expression == "@tsv" || expression == "@csv" {
    if expression == "@tsv" {
      Ok([Json::string(jq_join_value(value, "\t"))])
    } else {
      match value {
        Array(items) => Ok([Json::string(items.map(jq_csv_value).join(","))])
        _ => Ok([Json::string(jq_csv_value(value))])
      }
    }
  } else if expression.contains("//") {
    let (left, right) = match expression.split_once("//") {
      Some(pair) => pair
      None => return Err("malformed jq fallback")
    }
    let selected = match jq_eval(value, left.trim().to_owned()) {
      Ok(values) => values
      Err(error) => return Err(error)
    }
    if selected.any(item => !Json::equal(item, Json::null())) {
      Ok(selected)
    } else {
      jq_eval(value, right.trim().to_owned())
    }
  } else if expression == "." {
    Ok([value])
  } else if expression.has_prefix(".") {
    jq_path_values(value, expression)
  } else {
    match filter_literal(expression) {
      Ok(value) => Ok([value])
      Err(error) => Err(error)
    }
  }
}

///|
fn render_jq_full(value : Json, expression : String) -> Result[String, String] {
  let expression = expression.trim().to_owned()
  guard !expression.is_empty() else { return Err("empty jq expression") }
  let pipeline = match split_filter_parts(expression, '|') {
    Ok(parts) => parts
    Err(error) => return Err(error)
  }
  let mut values : Array[Json] = [value]
  for stage in pipeline {
    let stage = stage.trim().to_owned()
    guard !stage.is_empty() else { return Err("malformed jq pipeline") }
    let next : Array[Json] = []
    for item in values {
      match jq_eval(item, stage) {
        Ok(items) => next.append(items)
        Err(error) => return Err(error)
      }
    }
    values = next
  }
  let out = StringBuilder()
  for item in values {
    out.write_string(json_to_filter_text(item))
    out.write_char('\n')
  }
  Ok(out.to_string())
}

///|
fn template_value(value : Json, expression : String) -> Result[String, String] {
  let expression = expression.trim().to_owned()
  if expression.has_prefix("json ") || expression.has_prefix("toJSON ") {
    let offset = if expression.has_prefix("json ") { 5 } else { 7 }
    let selected = match jq_eval(value, expression[offset:].trim().to_owned()) {
      Ok(items) => items.get(0).unwrap_or(Json::null())
      Err(_) => return Err("unsupported template expression")
    }
    return Ok(selected.stringify())
  }
  if expression == "json" || expression == "toJSON" {
    return Ok(value.stringify())
  }
  if expression.has_prefix("printf ") {
    let words = match
      split_filter_parts(expression[7:].trim().to_owned(), ' ') {
      Ok(parts) => parts
      Err(_) => return Err("unsupported template printf")
    }
    let words = words
      .map(word => word.trim().to_owned())
      .filter(word => !word.is_empty())
    guard words.get(0) is Some(format) else {
      return Err("unsupported template printf")
    }
    let format_value = match filter_literal(format) {
      Ok(String(text)) => text
      _ => return Err("unsupported template printf")
    }
    let arguments : Array[String] = []
    for word in words[1:] {
      match template_value(value, word) {
        Ok(text) => arguments.push(text)
        Err(_) =>
          match filter_literal(word) {
            Ok(literal) => arguments.push(json_to_filter_text(literal))
            Err(_) => return Err("unsupported template printf")
          }
      }
    }
    return Ok(template_printf(format_value, arguments))
  }
  if expression.has_prefix("join ") {
    let words = match
      split_filter_parts(expression[5:].trim().to_owned(), ' ') {
      Ok(parts) => parts
      Err(_) => return Err("unsupported template join")
    }
    let words = words
      .map(word => word.trim().to_owned())
      .filter(word => !word.is_empty())
    guard words.length() >= 2 else { return Err("unsupported template join") }
    let separator = match filter_literal(words[0]) {
      Ok(String(text)) => text
      _ => return Err("unsupported template join")
    }
    let selected = match jq_eval(value, words[1]) {
      Ok(items) => items.get(0).unwrap_or(Json::null())
      Err(_) => return Err("unsupported template join")
    }
    return Ok(jq_join_value(selected, separator))
  }
  if expression.has_prefix("truncate ") {
    let words = match template_argument_words(expression[9:].to_owned()) {
      Ok(words) => words
      Err(error) => return Err(error)
    }
    guard words.length() == 2 else {
      return Err("truncate expects a length and a value")
    }
    let length = match filter_literal(words[0]) {
      Ok(Number(number, ..)) if number >= 0.0 && number.floor() == number =>
        number.to_int()
      _ => return Err("truncate length must be a non-negative integer")
    }
    let selected = match jq_eval(value, words[1]) {
      Ok(items) => jq_first(items)
      Err(_) => return Err("unsupported template truncate")
    }
    let text = json_to_filter_text(selected)
    if text.length() <= length {
      return Ok(text)
    }
    if length <= 3 {
      return Ok(text[:length].to_owned())
    }
    return Ok(text[:length - 3].to_owned() + "...")
  }
  if expression.has_prefix("hyperlink ") {
    let words = match template_argument_words(expression[10:].to_owned()) {
      Ok(words) => words
      Err(error) => return Err(error)
    }
    guard words.length() == 2 else {
      return Err("hyperlink expects a URL and text")
    }
    // Piped output is plain text in gh; preserve URL parsing as an argument
    // check without emitting terminal OSC-8 sequences in non-TTY output.
    match jq_eval(value, words[0]) {
      Ok(_) => ()
      Err(_) =>
        match filter_literal(words[0]) {
          Ok(_) => ()
          Err(_) => return Err("unsupported hyperlink URL")
        }
    }
    let text = match jq_eval(value, words[1]) {
      Ok(items) => json_to_filter_text(jq_first(items))
      Err(_) =>
        match filter_literal(words[1]) {
          Ok(item) => json_to_filter_text(item)
          Err(_) => return Err("unsupported hyperlink text")
        }
    }
    return Ok(text)
  }
  if expression.has_prefix("color ") || expression.has_prefix("autocolor ") {
    let autocolor = expression.has_prefix("autocolor ")
    let offset = if autocolor { 10 } else { 6 }
    let words = match template_argument_words(expression[offset:].to_owned()) {
      Ok(words) => words
      Err(error) => return Err(error)
    }
    guard words.length() == 2 else {
      return Err("color expects a style and value")
    }
    let style = match filter_literal(words[0]) {
      Ok(String(text)) => text
      _ => return Err("color style must be a string")
    }
    let selected = match jq_eval(value, words[1]) {
      Ok(items) => json_to_filter_text(jq_first(items))
      Err(_) =>
        match filter_literal(words[1]) {
          Ok(item) => json_to_filter_text(item)
          Err(_) => return Err("unsupported color value")
        }
    }
    return Ok(
      if autocolor {
        selected
      } else {
        template_color(style, selected)
      },
    )
  }
  if expression.has_prefix("tablerow ") {
    let words = match template_argument_words(expression[9:].to_owned()) {
      Ok(words) => words
      Err(error) => return Err(error)
    }
    let cells : Array[String] = []
    for word in words {
      let cell = match jq_eval(value, word) {
        Ok(items) => json_to_filter_text(jq_first(items))
        Err(_) =>
          match filter_literal(word) {
            Ok(item) => json_to_filter_text(item)
            Err(_) => return Err("unsupported tablerow value")
          }
      }
      cells.push(cell)
    }
    return Ok(cells.join("  ") + "\n")
  }
  if expression == "tablerender" {
    return Ok("")
  }
  if expression.has_prefix("contains ") ||
    expression.has_prefix("hasPrefix ") ||
    expression.has_prefix("hasSuffix ") {
    let name = if expression.has_prefix("contains ") {
      "contains"
    } else if expression.has_prefix("hasPrefix ") {
      "hasPrefix"
    } else {
      "hasSuffix"
    }
    let offset = name.length() + 1
    let words = match split_filter_parts(expression[offset:].to_owned(), ' ') {
      Ok(parts) =>
        parts
        .map(word => word.trim().to_owned())
        .filter(word => !word.is_empty())
      Err(_) => return Err("unsupported template predicate")
    }
    guard words.length() == 1 || words.length() == 2 else {
      return Err("unsupported template predicate")
    }
    let subject = if words.length() == 1 {
      value
    } else {
      match jq_eval(value, words[0]) {
        Ok(items) => jq_first(items)
        Err(_) => return Err("unsupported template predicate")
      }
    }
    let argument_word = if words.length() == 1 { words[0] } else { words[1] }
    let argument = match jq_eval(value, argument_word) {
      Ok(items) => jq_first(items)
      Err(_) =>
        match filter_literal(argument_word) {
          Ok(literal) => literal
          Err(_) => return Err("unsupported template predicate")
        }
    }
    let result = match name {
      "contains" => jq_contains(subject, argument)
      "hasPrefix" =>
        match (subject, argument) {
          (String(left), String(right)) => left.has_prefix(right)
          _ => false
        }
      _ =>
        match (subject, argument) {
          (String(left), String(right)) => left.has_suffix(right)
          _ => false
        }
    }
    return Ok(if result { "true" } else { "false" })
  }
  if expression.has_prefix("\"") || expression.has_prefix("'") {
    let literal = match filter_literal(expression) {
      Ok(value) => value
      Err(_) => return Err("unsupported template expression")
    }
    return match literal {
      String(text) => Ok(text)
      _ => Err("unsupported template literal")
    }
  }
  guard expression.has_prefix(".") else {
    return Err("unsupported template expression")
  }
  let path = match parse_path(expression) {
    Ok(path) => path
    Err(error) => return Err(error)
  }
  Ok(json_to_filter_text(lookup_json(value, path)))
}

///|
fn template_printf(format : String, arguments : Array[String]) -> String {
  let out = StringBuilder()
  let mut index = 0
  let mut cursor = 0
  while cursor < format.length() {
    let ch = format.get_char(cursor).unwrap_or('\u{0}')
    if ch == '%' && cursor + 1 < format.length() {
      let code = format.get_char(cursor + 1).unwrap_or('\u{0}')
      if code == '%' {
        out.write_char('%')
        cursor += 2
        continue
      }
      if code == 's' || code == 'v' || code == 'd' {
        out.write_string(arguments.get(index).unwrap_or(""))
        index += 1
        cursor += 2
        continue
      }
    }
    out.write_char(ch)
    cursor += 1
  }
  out.to_string()
}

///|
/// Return the ANSI code for a gh template color/style name.
fn template_color_code(style : String) -> String? {
  match style.trim().to_lower() {
    "black" => Some("30")
    "red" => Some("31")
    "green" => Some("32")
    "yellow" => Some("33")
    "blue" => Some("34")
    "magenta" => Some("35")
    "cyan" => Some("36")
    "white" => Some("37")
    "gray" | "grey" => Some("90")
    "bold" => Some("1")
    "dim" => Some("2")
    "underline" => Some("4")
    _ => None
  }
}

///|
fn template_color(style : String, value : String) -> String {
  let codes : Array[String] = []
  for part in style.split(" ") {
    if !part.is_empty() && template_color_code(part.to_owned()) is Some(code) {
      codes.push(code)
    }
  }
  if codes.is_empty() {
    value
  } else {
    "\u{001b}[" + codes.join(";") + "m" + value + "\u{001b}[0m"
  }
}

///|
fn template_argument_words(source : String) -> Result[Array[String], String] {
  let words = match split_filter_parts(source.trim().to_owned(), ' ') {
    Ok(parts) => parts
    Err(_) => return Err("malformed template arguments")
  }
  let words = words
    .map(word => word.trim().to_owned())
    .filter(word => !word.is_empty())
  if words.is_empty() {
    Err("missing template argument")
  } else {
    Ok(words)
  }
}

///|
fn template_truthy(value : Json) -> Bool {
  match value {
    Null => false
    True => true
    False => false
    String(text) => !text.is_empty()
    Array(items) => !items.is_empty()
    Object(fields) => !fields.is_empty()
    Number(number, ..) => number != 0.0
  }
}

///|
fn template_condition(
  value : Json,
  expression : String,
) -> Result[Json, String] {
  let expression = expression.trim().to_owned()
  if expression.has_prefix("eq ") ||
    expression.has_prefix("ne ") ||
    expression.has_prefix("lt ") ||
    expression.has_prefix("le ") ||
    expression.has_prefix("gt ") ||
    expression.has_prefix("ge ") {
    let operator = expression[:2].to_owned()
    let words = match split_filter_parts(expression[3:].to_owned(), ' ') {
      Ok(parts) =>
        parts
        .map(word => word.trim().to_owned())
        .filter(word => !word.is_empty())
      Err(_) => return Err("unsupported template condition")
    }
    guard words.length() == 2 else {
      return Err("unsupported template condition")
    }
    let left = match jq_eval(value, words[0]) {
      Ok(items) => jq_first(items)
      Err(error) => return Err(error)
    }
    let right = match jq_eval(value, words[1]) {
      Ok(items) => jq_first(items)
      Err(_) =>
        match filter_literal(words[1]) {
          Ok(literal) => literal
          Err(_) => return Err("unsupported template condition")
        }
    }
    let result = match operator {
      "eq" => Json::equal(left, right)
      "ne" => !Json::equal(left, right)
      "lt" | "le" | "gt" | "ge" =>
        json_compare(
          left,
          right,
          match operator {
            "lt" => "<"
            "le" => "<="
            "gt" => ">"
            _ => ">="
          },
        )
      _ => false
    }
    return Ok(Json::boolean(result))
  }
  if expression.has_prefix("not ") {
    let selected = match template_condition(value, expression[4:].to_owned()) {
      Ok(selected) => selected
      Err(error) => return Err(error)
    }
    return Ok(Json::boolean(!template_truthy(selected)))
  }
  match jq_eval(value, expression) {
    Ok(items) => Ok(jq_first(items))
    Err(error) => Err(error)
  }
}

///|
fn render_template_fragment(
  value : Json,
  source : String,
  stop~ : Bool = false,
) -> Result[(String, String), String] {
  let out = StringBuilder()
  let mut rest = source
  while true {
    match rest.split_once("{{") {
      None => {
        guard !stop else { return Ok((out.to_string(), rest)) }
        guard !rest.contains("}}") else {
          return Err("malformed template expression")
        }
        out.write_string(rest)
        return Ok((out.to_string(), ""))
      }
      Some((before, after_open)) => {
        out.write_string(before.to_owned())
        match after_open.split_once("}}") {
          None => return Err("malformed template expression")
          Some((raw_expression, after_close)) => {
            let expression = raw_expression.trim().to_owned()
            if expression == "end" {
              guard stop else { return Err("unexpected template end") }
              return Ok((out.to_string(), after_close.to_owned()))
            }
            if expression.has_prefix("range ") {
              let path = expression[6:].trim().to_owned()
              let selected = match jq_path_values(value, path) {
                Ok(items) => items
                Err(_) => return Err("unsupported template range")
              }
              let selected = match selected.get(0) {
                Some(Array(items)) => items
                _ => selected
              }
              let block = match after_close.split_once("{{end}}") {
                Some(pair) => pair
                None =>
                  return Err(
                    "unsupported template: unterminated template range",
                  )
              }
              let (body, empty_body) = match block.0.split_once("{{else}}") {
                Some(pair) => (pair.0.to_owned(), Some(pair.1.to_owned()))
                None => (block.0.to_owned(), None)
              }
              if selected.is_empty() {
                match empty_body {
                  Some(empty_body) => {
                    let rendered = match
                      render_template_fragment(value, empty_body) {
                      Ok(pair) => pair.0
                      Err(error) => return Err(error)
                    }
                    out.write_string(rendered)
                  }
                  None => ()
                }
              } else {
                for item in selected {
                  let rendered = match render_template_fragment(item, body) {
                    Ok(pair) => pair.0
                    Err(error) => return Err(error)
                  }
                  out.write_string(rendered)
                }
              }
              rest = block.1.to_owned()
              continue
            }
            if expression.has_prefix("if ") || expression.has_prefix("with ") {
              let path = if expression.has_prefix("if ") {
                expression[3:].trim().to_owned()
              } else {
                expression[5:].trim().to_owned()
              }
              let selected = match template_condition(value, path) {
                Ok(item) => item
                Err(_) => return Err("unsupported template condition")
              }
              let block = match after_close.split_once("{{end}}") {
                Some(pair) => pair
                None => return Err("unterminated template condition")
              }
              let (body, empty_body) = match block.0.split_once("{{else}}") {
                Some(pair) => (pair.0.to_owned(), Some(pair.1.to_owned()))
                None => (block.0.to_owned(), None)
              }
              if template_truthy(selected) {
                // `if` keeps the current dot context; `with` switches dot to
                // the selected value, matching Go template semantics.
                let context = if expression.has_prefix("with ") {
                  selected
                } else {
                  value
                }
                let rendered = match render_template_fragment(context, body) {
                  Ok(pair) => pair.0
                  Err(error) => return Err(error)
                }
                out.write_string(rendered)
              } else if empty_body is Some(empty_body) {
                let rendered = match
                  render_template_fragment(value, empty_body) {
                  Ok(pair) => pair.0
                  Err(error) => return Err(error)
                }
                out.write_string(rendered)
              }
              rest = block.1.to_owned()
              continue
            }
            let rendered = match template_value(value, expression) {
              Ok(rendered) => rendered
              Err(error) => return Err(error)
            }
            out.write_string(rendered)
            rest = after_close.to_owned()
          }
        }
      }
    }
  } nobreak {
    Err("unterminated template")
  }
}

///|
fn render_template(value : Json, template : String) -> Result[String, String] {
  match render_template_fragment(value, template) {
    Ok((rendered, rest)) if rest.is_empty() => Ok(rendered)
    Ok(_) => Err("unexpected template end")
    Err(error) => Err(error)
  }
}

///|
fn response_prefix(status : Int32, headers : Array[(String, String)]) -> Bytes {
  let lines = StringBuilder()
  let reason = status_text(status)
  lines.write_string("HTTP/1.1 " + status.to_string())
  if !reason.is_empty() {
    lines.write_string(" " + reason)
  }
  lines.write_char('\n')
  for (name, value) in headers {
    lines.write_string(name + ": " + value + "\n")
  }
  lines.write_char('\n')
  @utf8.encode(lines.to_string())
}

///|
/// Render the one-line API diagnostic used by `gh api`. GitHub's JSON error
/// body carries a user-facing `message`; preserve the raw body on stdout but
/// surface that message (when available) on stderr with the HTTP status.
fn error_line(status : Int32, body : Bytes) -> String {
  let reason = status_text(status)
  let text = @utf8.decode(body) catch { _ => "" }
  let value : Json = @json.parse(text) catch { _ => Json::null() }
  let message : String? = match value {
    Object(fields) =>
      match fields.get("message") {
        Some(String(value)) if !value.is_empty() => Some(value)
        _ => None
      }
    _ => None
  }
  match message {
    Some(value) => "gh: " + value + " (HTTP " + status.to_string() + ")\n"
    None if reason.is_empty() => "gh: HTTP " + status.to_string() + "\n"
    None => "gh: HTTP " + status.to_string() + " " + reason + "\n"
  }
}

///|
fn append_bytes(left : Bytes, right : Bytes) -> Bytes {
  Bytes::add(left, right)
}

///|
/// Render a raw API response while retaining byte-oriented stdout semantics.
pub fn render_response(
  status : Int32,
  headers : Array[(String, String)],
  body : Bytes,
  jq? : String,
  template? : String,
  include_headers~ : Bool = false,
  silent~ : Bool = false,
  verbose~ : Bool = false,
  allow_escape_sequences~ : Bool = false,
) -> Output {
  let prefix = if include_headers {
    response_prefix(status, headers)
  } else {
    Bytes::new(0)
  }
  let mut stderr = if verbose {
    "> request\n< HTTP/1.1 " +
    status.to_string() +
    " " +
    status_text(status) +
    "\n"
  } else {
    ""
  }
  let mut output_body = body
  match (jq, template) {
    (None, None) =>
      if !has_nul(body) {
        let text : String? = Some(@utf8.decode(body)) catch { _ => None }
        match text {
          Some(text) =>
            output_body = @utf8.encode(
              text_for_output(text, allow_escape_sequences),
            )
          None => ()
        }
      }
    (Some(expression), None) => {
      let text = @utf8.decode(body) catch {
        _ =>
          return failure(
            message="response is not valid UTF-8 JSON",
            exit_code=1,
          )
      }
      let value : Json = @json.parse(text) catch {
        _ => return failure(message="response is not valid JSON", exit_code=1)
      }
      let rendered = match render_jq_full(value, expression) {
        Ok(rendered) => rendered
        Err(error) => return failure(message=error, exit_code=1)
      }
      output_body = @utf8.encode(
        text_for_output(rendered, allow_escape_sequences),
      )
    }
    (None, Some(expression)) => {
      let text = @utf8.decode(body) catch {
        _ =>
          return failure(
            message="response is not valid UTF-8 JSON",
            exit_code=1,
          )
      }
      let value : Json = @json.parse(text) catch {
        _ => return failure(message="response is not valid JSON", exit_code=1)
      }
      let rendered = match render_template(value, expression) {
        Ok(rendered) => rendered
        Err(error) => return failure(message=error, exit_code=1)
      }
      output_body = @utf8.encode(
        text_for_output(rendered, allow_escape_sequences),
      )
    }
    (Some(_), Some(_)) =>
      return failure(message="cannot combine jq and template", exit_code=1)
  }
  let stdout = if silent {
    if include_headers {
      prefix
    } else {
      Bytes::new(0)
    }
  } else if include_headers {
    append_bytes(prefix, output_body)
  } else {
    output_body
  }
  if status < 200 || status >= 300 {
    stderr = stderr + error_line(status, body)
    return Output::from_bytes(
      stdout,
      stderr~,
      exit_code=if status == 401 { 4 } else { 1 },
    )
  }
  Output::from_bytes(stdout, stderr~)
}
