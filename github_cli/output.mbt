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
/// GitHub REST errors use the API message only when declared as JSON. Other
/// responses keep the HTTP reason phrase, including nonstandard proxy errors.
pub fn rest_error_message(
  status : Int32,
  headers : Array[(String, String)],
  body : Bytes,
  url : String,
  reason_phrase? : String,
) -> String {
  let json_body = headers.any(pair => {
    pair.0.equal_ignore_ascii_case("Content-Type") &&
    pair.1.to_lower().contains("json")
  })
  let message = if json_body { error_message(body) } else { None }
  let message = message.unwrap_or_else(() => {
    let reason = reason_phrase.unwrap_or_else(() => status_text(status))
    status.to_string() + (if reason.is_empty() { "" } else { " " + reason })
  })
  "HTTP " + status.to_string() + ": " + message + " (" + url + ")"
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
/// Render untrusted control bytes visibly, preserving their diagnostic content.
fn sanitize_terminal_escapes(text : String) -> String {
  let out = StringBuilder()
  for ch in text {
    let code = ch.to_int()
    if code < 32 && !(ch is ('\t' | '\n' | '\r')) {
      out.write_char('^')
      out.write_char((code + 64).unsafe_to_char())
    } else if code == 127 {
      out.write_string("^?")
    } else {
      out.write_char(ch)
    }
  }
  out.to_string()
}

///|
fn sanitized_json(value : Json, allow_escape_sequences : Bool) -> Json {
  if allow_escape_sequences {
    return value
  }
  match value {
    String(text) => Json(sanitize_terminal_escapes(text))
    Array(values) =>
      Json::array(values.map(value => sanitized_json(value, false)))
    Object(fields) => {
      let result : Map[String, Json] = Map([])
      for key, value in fields {
        result[sanitize_terminal_escapes(key)] = sanitized_json(value, false)
      }
      Json::object(result)
    }
    _ => value
  }
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
  match error_message(body) {
    Some(value) => "gh: " + value + " (HTTP " + status.to_string() + ")\n"
    None => "gh: HTTP " + status.to_string() + "\n"
  }
}

///|
fn error_message(body : Bytes) -> String? {
  let text = @utf8.decode(body) catch { _ => "" }
  let value : Json = @json.parse(text) catch { _ => Json::null() }
  match value {
    Object(fields) =>
      match fields.get("message") {
        Some(String(value)) if !value.is_empty() => Some(value)
        _ => None
      }
    _ => None
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
  format_context~ : FormatContext = FormatContext::new(),
) -> Output {
  let text = Some(@utf8.decode(body)) catch { _ => None }
  let json_body = text.map_or(false, value => {
    try {
      ignore(@json.parse(value))
      true
    } catch {
      _ => false
    }
  })
  let body = if json_body && !allow_escape_sequences && text is Some(text) {
    @utf8.encode(@formatter_common.sanitize_wire_json(text))
  } else {
    body
  }
  let server_error = status >= 400 && error_message(body) is Some(_)
  let jq = if jq == Some("") || server_error { None } else { jq }
  let template = if template == Some("") || server_error {
    None
  } else {
    template
  }
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
  let mut formatter_failed = false
  match (jq, template) {
    (None, None) =>
      if !has_nul(body) {
        let text : String? = Some(@utf8.decode(body)) catch { _ => None }
        match text {
          Some(text) => {
            let text = if json_body && format_context.terminal {
              let pretty = @formatter_common.pretty_wire_json(text)
              if format_context.color {
                @formatter_common.color_json(pretty, punctuation="1;37")
              } else {
                pretty
              }
            } else {
              text_for_output(text, allow_escape_sequences)
            }
            output_body = @utf8.encode(text)
          }
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
      let (rendered, error) = @formatter_jq.render(
        sanitized_json(value, allow_escape_sequences),
        expression,
        indent=if format_context.terminal { 2 } else { 0 },
        color=format_context.color,
        environment=format_context.environment,
      )
      if error is Some(message) {
        formatter_failed = true
        stderr += message + "\n"
      }
      output_body = @utf8.encode(rendered)
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
      let (rendered, error) = @formatter_template.format(
        sanitized_json(value, allow_escape_sequences),
        expression,
        terminal=format_context.color,
        width=format_context.width,
        now_unix=format_context.now_unix,
        local_zone?=format_context.local_zone,
      )
      if error is Some(message) {
        formatter_failed = true
        stderr += message + "\n"
      }
      output_body = @utf8.encode(rendered)
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
  if formatter_failed {
    return Output::from_bytes(stdout, stderr~, exit_code=1)
  }
  if status < 200 || status >= 300 {
    stderr = stderr + error_line(status, body)
    return Output::from_bytes(stdout, stderr~, exit_code=1)
  }
  Output::from_bytes(stdout, stderr~)
}
