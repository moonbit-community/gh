///|
fn from_json(value : Json) -> Value {
  match value {
    Null => Null
    True => Bool(true)
    False => Bool(false)
    Number(value, ..) => Float(value)
    String(value) => Str(value)
    Array(values) => List(values.map(from_json))
    Object(fields) => {
      let values : Map[String, Value] = Map([])
      for name, value in fields {
        values[name] = from_json(value)
      }
      Dict(values)
    }
  }
}

///|
fn require_string(
  values : Array[Value],
  index : Int32,
  name : String,
) -> String raise TemplateError {
  match arg_at(values, index, name) {
    Str(value) => value
    _ => raise ExecError(name + ": expected string")
  }
}

///|
fn gh_scalar(value : Value) -> String raise TemplateError {
  match value {
    Null => ""
    Str(value) => value
    Float(value) => @formatter_common.scalar_number(value)
    Bool(value) => if value { "true" } else { "false" }
    _ => raise ExecError("cannot convert type to string: " + to_output(value))
  }
}

///|
fn gh_functions(
  template : Template,
  terminal : Bool,
  output : StringBuilder,
  width : Int32,
  now_unix : Int64,
  local_zone : @time.Zone?,
) -> Unit {
  let allowed = [
    "eq", "ne", "lt", "le", "gt", "ge", "and", "or", "not", "len", "index", "printf",
    "print", "println", "contains", "hasPrefix", "hasSuffix", "replace",
  ]
  for name in template.funcs.keys().collect() {
    if !allowed.contains(name) {
      template.funcs.remove(name)
    }
  }
  template.funcs["slice"] = go_slice
  template.funcs["html"] = values => {
    Str(go_html(values.map(to_output).join("")))
  }
  template.funcs["urlquery"] = values => {
    Str(go_urlquery(values.map(to_output).join("")))
  }
  template.funcs["len"] = values => {
    match arg_at(values, 0, "len") {
      Str(value) => Int(@utf8.encode(value).length().to_int64())
      List(values) => Int(values.length().to_int64())
      Dict(values) => Int(values.length().to_int64())
      _ => raise ExecError("len: value has no length")
    }
  }
  template.funcs["join"] = values => {
    let separator = require_string(values, 0, "join")
    guard arg_at(values, 1, "join") is List(items) else {
      raise ExecError("join: expected array")
    }
    Str(items.map(gh_scalar).join(separator))
  }
  template.funcs["pluck"] = values => {
    let field = require_string(values, 0, "pluck")
    guard arg_at(values, 1, "pluck") is List(items) else {
      raise ExecError("pluck: expected array")
    }
    let result : Array[Value] = []
    for item in items {
      guard item is Dict(fields) else {
        raise ExecError("pluck: expected object")
      }
      result.push(fields.get(field).unwrap_or(Null))
    }
    List(result)
  }
  template.funcs["truncate"] = values => {
    let length = match arg_at(values, 0, "truncate") {
      Int(value) => value.to_int()
      _ => raise ExecError("truncate: expected integer")
    }
    let raw = arg_at(values, 1, "truncate")
    if raw is Null {
      return Str("")
    }
    let value = require_string(values, 1, "truncate")
    guard length >= 0 else { raise ExecError("truncate: negative length") }
    Str(truncate_display(value, length))
  }
  for name in ["color", "autocolor"] {
    template.funcs[name] = values => {
      let style = require_string(values, 0, name)
      let value = gh_scalar(arg_at(values, 1, name))
      if !terminal {
        return Str(value)
      }
      Str(color_style(value, style))
    }
  }
  template.funcs["hyperlink"] = values => {
    let url = require_string(values, 0, "hyperlink")
    let text = require_string(values, 1, "hyperlink")
    let text = if text.is_empty() { url } else { text }
    Str("\u001b]8;;" + url + "\u001b\\" + text + "\u001b]8;;\u001b\\")
  }
  template.funcs["regexMatch"] = values => {
    let expression = require_string(values, 0, "regexMatch")
    let text = require_string(values, 1, "regexMatch")
    Bool(
      @regexp.compile(expression).execute(text).matched() catch {
        _ => false
      },
    )
  }
  template.funcs["timefmt"] = values => {
    Str(
      time_format(
        require_string(values, 0, "timefmt"),
        require_string(values, 1, "timefmt"),
        local_zone,
      ),
    )
  }
  template.funcs["timeago"] = values => {
    Str(time_ago(require_string(values, 0, "timeago"), now_unix))
  }
  let rows : Array[Array[String]] = []
  template.funcs["tablerow"] = values => {
    rows.push(
      values.map(gh_scalar) catch {
        ExecError(message) =>
          raise ExecError("failed to write table row: " + message)
        error => raise error
      },
    )
    Str("")
  }
  template.funcs["tablerender"] = _values => {
    let widths : Array[Int32] = []
    for row in rows {
      for index, cell in row {
        if index >= widths.length() {
          widths.push(0)
        }
        // Control characters have zero width in gh's text width accounting.
        let visible = StringBuilder()
        for ch in cell.iter() {
          if ch.to_int() >= 32 && ch.to_int() != 127 {
            visible.write_char(ch)
          }
        }
        widths[index] = widths[index].max(
          @unicodewidth.str_width(visible.to_string()),
        )
      }
    }
    let widths = table_column_widths(widths, width)
    let columns = rows.get(0).map_or(0, row => row.length())
    for row in rows {
      for index, cell in row {
        if index > 0 {
          output.write_string("  ")
        }
        let cell = match (cell.find("\n"), cell.find("\r")) {
          (Some(a), Some(b)) => cell[:a.min(b)].to_owned() + "..."
          (Some(a), None) | (None, Some(a)) => cell[:a].to_owned() + "..."
          (None, None) => cell
        }
        let cell = truncate_display(cell, widths[index])
        output.write_string(cell)
        if index < columns - 1 {
          output.write_string(
            " ".repeat((widths[index] - @unicodewidth.str_width(cell)).max(0)),
          )
        }
      }
      if !row.is_empty() {
        output.write_char('\n')
      }
    }
    rows.clear()
    Str("")
  }
}

///|
pub fn format(
  value : Json,
  expression : String,
  terminal~ : Bool = false,
  width~ : Int32 = 80,
  now_unix~ : Int64 = 0L,
  local_zone? : @time.Zone,
) -> (String, String?) {
  let output = StringBuilder()
  try {
    let template = Template::new()
    gh_functions(template, terminal, output, width, now_unix, local_zone)
    ignore(template.parse(expression))
    (template.renderer)(from_json(value), output)
    ignore(template.funcs["tablerender"]([]))
    (output.to_string(), None)
  } catch {
    ParseError(message) => ("", Some("template: :1: " + message))
    ExecError(message) => (output.to_string(), Some("template: :1: " + message))
    LocatedExec(message) => (output.to_string(), Some(message))
    LocatedParse(line, message) => ("", Some("template: :\{line}: " + message))
    LoopControl(_) =>
      (output.to_string(), Some("template: loop control outside range"))
    CommandError(_, _, message) => (output.to_string(), Some(message))
  }
}
