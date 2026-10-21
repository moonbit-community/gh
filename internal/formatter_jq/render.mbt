///|
fn write_json(
  value : Json,
  output : StringBuilder,
  indent : Int32,
  level : Int32,
) -> Unit {
  fn newline(depth : Int32) {
    if indent > 0 {
      output.write_char('\n')
      output.write_string(" ".repeat(indent * depth))
    }
  }
  match value {
    Number(_) => output.write_string(value.stringify())
    Array(values) => {
      output.write_char('[')
      for index, value in values {
        if index > 0 {
          output.write_char(',')
        }
        newline(level + 1)
        write_json(value, output, indent, level + 1)
      }
      if !values.is_empty() {
        newline(level)
      }
      output.write_char(']')
    }
    Object(fields) => {
      let names = fields.keys().collect()
      names.sort_by(@formatter_common.compare_text)
      output.write_char('{')
      for index, name in names {
        if index > 0 {
          output.write_char(',')
        }
        newline(level + 1)
        output.write_string(Json(name).stringify())
        output.write_string(if indent > 0 { ": " } else { ":" })
        write_json(fields[name], output, indent, level + 1)
      }
      if !names.is_empty() {
        newline(level)
      }
      output.write_char('}')
    }
    _ => output.write_string(value.stringify())
  }
}

///|
fn json_text(value : Json, indent : Int32) -> String {
  let output = StringBuilder()
  write_json(value, output, indent, 0)
  let text = output.to_string()
  text
  .replace_all(old="<", new="\\u003c")
  .replace_all(old=">", new="\\u003e")
  .replace_all(old="&", new="\\u0026")
  .replace_all(old="\u2028", new="\\u2028")
  .replace_all(old="\u2029", new="\\u2029")
}

///|
/// Partial stdout is returned alongside an evaluation error. gh emits each
/// result as it is produced; a later failure must not erase earlier results.
pub fn render(
  value : Json,
  expression : String,
  indent~ : Int32 = 0,
  color~ : Bool = false,
  environment~ : Map[String, String] = Map([]),
) -> (String, String?) {
  // The gh command wrapper treats an empty --jq option as no formatter.
  if expression.is_empty() {
    return (value.stringify(), None)
  }
  let output = StringBuilder()
  try {
    let query = @moonjq.parse(expression)
    @jq_ast.eval_stream(
      query.expr,
      gh_json_input(value),
      item => {
        let text = match item {
          Null => ""
          String(text) => text
          Number(_, repr=Some(integer)) => integer
          Number(value, ..) => @formatter_common.scalar_number(value)
          Array(_) | Object(_) => {
            let text = json_text(item, indent)
            if color {
              @formatter_common.color_json(text)
            } else {
              text
            }
          }
          _ => json_text(item, indent)
        }
        output.write_string(text)
        output.write_char('\n')
      },
      environment~,
    )
    (output.to_string(), None)
  } catch {
    @jq_ast.EvalError(message) => (output.to_string(), Some(message))
    @jq_ast.UserError(value) => {
      let message = match value {
        String(text) => text
        _ => json_text(value, 0)
      }
      (output.to_string(), Some("error: " + message))
    }
    @jq_parser.Located(offset, token) => {
      let prefix = expression[:offset]
      let lines = prefix.split("\n").collect()
      let line_start = offset - lines.last().unwrap_or("").length()
      let line = expression[line_start:]
        .split("\n")
        .next()
        .unwrap_or("")
        .to_owned()
      let column = @utf8.encode(expression[line_start:offset]).length() + 1
      let diagnostic = if token.is_empty() {
        "unexpected EOF"
      } else {
        "unexpected token " + Json(token).stringify()
      }
      (
        "",
        Some(
          "failed to parse jq expression (line \{lines.length()}, column \{column})\n" +
          "    " +
          line +
          "\n    " +
          " ".repeat(column - 1) +
          "^  " +
          diagnostic,
        ),
      )
    }
    @jq_parser.UnexpectedEnd(_) | @jq_parser.UnexpectedToken("TEof", _) => {
      let lines = expression.split("\n").collect()
      let line = lines.last().unwrap_or("").to_owned()
      let column = line.length() + 1
      (
        "",
        Some(
          "failed to parse jq expression (line \{lines.length()}, column \{column})\n" +
          "    " +
          line +
          "\n    " +
          " ".repeat(column - 1) +
          "^  unexpected EOF",
        ),
      )
    }
    error => (output.to_string(), Some(error.to_string()))
  }
}

///|
/// gh decodes API JSON into float64 before passing it to gojq. In particular,
/// exact JSON number lexemes must not be confused with jq integer literals.
fn gh_json_input(value : Json) -> Json {
  match value {
    Number(number, ..) => Json::number(number)
    Array(values) => Json(values.map(gh_json_input))
    Object(fields) => {
      let result : Map[String, Json] = Map([])
      for name, value in fields {
        result[name] = gh_json_input(value)
      }
      Json::object(result)
    }
    _ => value
  }
}
