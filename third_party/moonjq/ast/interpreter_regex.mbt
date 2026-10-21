///|
fn regex_arity(name : String, count : Int32) -> Bool {
  match name {
    "test" | "match" | "capture" | "scan" | "splits" => count is (1 | 2)
    "sub" | "gsub" => count is (2 | 3)
    _ => false
  }
}

///|
fn compile_regex(
  pattern : String,
  flags : String,
) -> @regexp.Regexp raise InterpreterError {
  for ch in flags {
    guard ch is ('g' | 'i' | 'm') else {
      raise EvalError(
        "unsupported regular expression flag: " + Json(flags).stringify(),
      )
    }
  }
  let chars = pattern.iter().collect()
  let mut cursor = 0
  while cursor + 1 < chars.length() {
    if chars[cursor] == '\\' {
      if chars[cursor + 1] is ('1'..<='9') &&
        !(cursor + 3 < chars.length() &&
        chars[cursor + 2] is ('0'..<='7') &&
        chars[cursor + 3] is ('0'..<='7')) {
        raise EvalError(
          "invalid regular expression " +
          Json(pattern).stringify() +
          ": error parsing regexp: invalid escape sequence: `\\" +
          chars[cursor + 1].to_string() +
          "`",
        )
      }
      cursor += 2
    } else {
      cursor += 1
    }
  }
  let native_flags = (if flags.contains("i") { "i" } else { "" }) +
    (if flags.contains("m") { "s" } else { "" })
  @regexp.compile(pattern, flags=native_flags) catch {
    RegexpError(err~, source_fragment~) => {
      let detail = match err {
        MissingBracket => "missing closing ]"
        MissingParenthesis => "missing closing )"
        UnexpectedParenthesis => "unexpected )"
        TrailingBackslash => "trailing backslash at end of expression"
        MissingRepeatArgument => "missing argument to repetition operator"
        InvalidRepeatOp => "invalid nested repetition operator"
        InvalidRepeatSize => "invalid repeat count"
        InvalidCharClass => "invalid character class"
        InvalidNamedCapture => "invalid named capture"
        InvalidEscape => "invalid escape sequence"
        _ => "invalid regular expression"
      }
      let fragment = if source_fragment.is_empty() {
        pattern
      } else {
        source_fragment.to_owned()
      }
      raise EvalError(
        "invalid regular expression " +
        Json(pattern).stringify() +
        ": error parsing regexp: " +
        detail +
        ": `" +
        fragment +
        "`",
      )
    }
  }
}

///|
fn regex_matches(
  expression : @regexp.Regexp,
  text : String,
  global : Bool,
) -> Array[@regexp.MatchResult] {
  let results = []
  let mut offset = 0
  let mut previous_end = -1
  while offset <= text.length() {
    let result = expression.execute_from(text, offset)
    guard result.get(0) is Some(found) else { break }
    let start = found.start_offset()
    let end = start + found.length()
    // Go FindAll discards an empty match directly after a nonempty match.
    if end > start || start != previous_end {
      results.push(result)
    }
    if !global {
      break
    }
    previous_end = end
    offset = if start == end {
      end +
      text
      .get_char(end)
      .map_or(1, ch => if ch.to_int() > 0xffff { 2 } else { 1 })
    } else {
      end
    }
  }
  results
}

///|
fn capture_values(
  expression : @regexp.Regexp,
  result : @regexp.MatchResult,
) -> Json {
  let fields : Map[String, Json] = Map([])
  for name in expression.group_names() {
    if expression.group_by_name(name) is Some(index) {
      fields[name] = result
        .get(index)
        .map_or(Json::null(), value => Json(value.to_owned()))
    }
  }
  Json::object(fields)
}

///|
fn match_value(
  expression : @regexp.Regexp,
  result : @regexp.MatchResult,
  text : String,
) -> Json {
  let names : Map[Int32, String] = Map([])
  for name in expression.group_names() {
    if expression.group_by_name(name) is Some(index) {
      names[index] = name
    }
  }
  let captures : Array[Json] = []
  for index in 1..<expression.group_count() {
    let capture = result.get(index)
    captures.push({
      "offset": capture.map_or(-1, value => {
        text[:value.start_offset()].char_length()
      }),
      "length": capture.map_or(0, value => value.char_length()),
      "string": capture.map_or(Json::null(), value => Json(value.to_owned())),
      "name": names.get(index).map_or(Json::null(), value => Json(value)),
    })
  }
  let found = result.get(0).unwrap()
  {
    "offset": text[:found.start_offset()].char_length(),
    "length": found.char_length(),
    "string": found.to_owned(),
    "captures": captures,
  }
}

///|
fn regex_replace(
  expression : @regexp.Regexp,
  matches : Array[@regexp.MatchResult],
  text : String,
  replacement : Expr,
  env : Env,
) -> Array[Json] raise InterpreterError {
  if matches.is_empty() {
    return [Json(text)]
  }
  let replacements : Array[Array[String]] = []
  for found in matches {
    let values = eval_with_env(
      replacement,
      capture_values(expression, found),
      env,
    ).collect()
    let strings : Array[String] = []
    for value in values {
      match value {
        Null => strings.push("")
        String(value) => strings.push(value)
        _ =>
          raise EvalError("cannot add: string (\"\") and " + gh_describe(value))
      }
    }
    replacements.push(strings)
  }
  let outputs : Array[Json] = []
  let variants = replacements
    .iter()
    .fold(init=0, (count, values) => count.max(values.length()))
  for variant in 0..<variants {
    let output = StringBuilder()
    let mut end = 0
    for index, found in matches {
      let span = found.get(0).unwrap()
      output.write_view(text[end:span.start_offset()])
      output.write_string(replacements[index].get(variant).unwrap_or(""))
      end = span.start_offset() + span.length()
    }
    output.write_view(text[end:])
    outputs.push(Json(output.to_string()))
  }
  outputs
}

///|
fn eval_regex_stream(
  name : String,
  args : Array[Expr],
  input : Json,
  env : Env,
  emit : (Json) -> Unit raise InterpreterError,
) -> Unit raise InterpreterError {
  let replacing = name is ("sub" | "gsub")
  let flags_index = if replacing { 2 } else { 1 }
  let flags_values = if args.length() > flags_index {
    eval_with_env(args[flags_index], input, env).collect()
  } else {
    [Json::null()]
  }
  for pattern_value in eval_with_env(args[0], input, env) {
    for flags_value in flags_values {
      let error = (if name == "test" { "test" } else { "match" }) +
        "(" +
        pattern_value.stringify() +
        "; " +
        flags_value.stringify() +
        ") cannot be applied to: " +
        gh_describe(input)
      guard input is String(text) && pattern_value is String(pattern) else {
        raise EvalError(error)
      }
      let flags = match flags_value {
        Null => ""
        String(value) => value
        _ => raise EvalError(error)
      }
      let expression = compile_regex(pattern, flags)
      let matches = regex_matches(
        expression,
        text,
        name is ("gsub" | "splits" | "scan") || flags.contains("g"),
      )
      match name {
        "test" => emit(Json(!matches.is_empty()))
        "match" =>
          for found in matches {
            emit(match_value(expression, found, text))
          }
        "capture" =>
          for found in matches {
            emit(capture_values(expression, found))
          }
        "scan" =>
          for found in matches {
            if expression.group_count() == 1 {
              emit(Json(found.get(0).unwrap().to_owned()))
            } else {
              emit(
                Json::array(
                  found.results()[1:].map(value => {
                    value.map_or(Json::null(), text => Json(text.to_owned()))
                  }),
                ),
              )
            }
          }
        "splits" => {
          let mut end = 0
          for found in matches {
            let span = found.get(0).unwrap()
            emit(Json(text[end:span.start_offset()].to_owned()))
            end = span.start_offset() + span.length()
          }
          emit(Json(text[end:].to_owned()))
        }
        "sub" | "gsub" =>
          for value in regex_replace(expression, matches, text, args[1], env) {
            emit(value)
          }
        _ => ()
      }
    }
  }
}

///|
fn eval_regex_call(
  name : String,
  args : Array[Expr],
  input : Json,
  env : Env,
) -> Iter[Json] raise InterpreterError {
  let values : Array[Json] = []
  eval_regex_stream(name, args, input, env, value => values.push(value))
  values.iter()
}

///|
fn eval_test(
  pattern : String,
  input : Json,
) -> Iter[Json] raise InterpreterError {
  eval_regex_call("test", [Literal(String(pattern))], input, Env::new())
}

///|
fn eval_match(
  pattern : String,
  input : Json,
) -> Iter[Json] raise InterpreterError {
  eval_regex_call("match", [Literal(String(pattern))], input, Env::new())
}

///|
fn eval_capture(
  pattern : String,
  input : Json,
) -> Iter[Json] raise InterpreterError {
  eval_regex_call("capture", [Literal(String(pattern))], input, Env::new())
}

///|
fn eval_splits(
  pattern : String,
  input : Json,
) -> Iter[Json] raise InterpreterError {
  eval_regex_call("splits", [Literal(String(pattern))], input, Env::new())
}

///|
fn eval_sub(
  pattern : String,
  replacement : String,
  input : Json,
) -> Iter[Json] raise InterpreterError {
  eval_regex_call(
    "sub",
    [Literal(String(pattern)), Literal(String(replacement))],
    input,
    Env::new(),
  )
}

///|
fn eval_gsub(
  pattern : String,
  replacement : String,
  input : Json,
) -> Iter[Json] raise InterpreterError {
  eval_regex_call(
    "gsub",
    [Literal(String(pattern)), Literal(String(replacement))],
    input,
    Env::new(),
  )
}
