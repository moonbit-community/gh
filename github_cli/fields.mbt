///|
/// Convert the scalar forms documented by `gh api -F`.
pub fn typed_field(value : String) -> Json {
  match value {
    "true" => Json::boolean(true)
    "false" => Json::boolean(false)
    "null" => Json::null()
    _ => {
      let number = @string.parse_int64(value) catch {
        _ => return Json::string(value)
      }
      Json::number(number.to_double(), repr=number.to_string())
    }
  }
}

///|
/// Build the GraphQL envelope: query and operationName stay top-level;
/// remaining field parameters become variables.
pub fn graphql_payload(fields : Map[String, Json]) -> Json {
  let top : Map[String, Json] = Map([])
  let variables : Map[String, Json] = Map([])
  for key, value in fields {
    if key == "query" || key == "operationName" {
      top[key] = value
    } else {
      variables[key] = value
    }
  }
  if !variables.is_empty() {
    top["variables"] = Json::object(variables)
  }
  Json::object(top)
}

///|
/// Encode simple fields as repeated GET query parameters.
pub fn query_fields(fields : Array[(String, Json)]) -> Array[(String, String)] {
  let output : Array[(String, String)] = []
  for (key, value) in fields {
    append_query_field(output, key, value)
  }
  output
}

///|
/// A parsed `-f/--field` path. Empty brackets append to an array; a named
/// bracket selects an object member. This is intentionally kept private so
/// callers continue to use the stable pair-based API.
priv enum FieldPart {
  FieldKey(String)
  FieldArray
}

///|
/// Mutable construction form used before converting to Json. Returning a new
/// node from insertion keeps all conflict checks explicit and avoids silently
/// replacing a value supplied by the caller.
priv enum FieldNode {
  FieldValue(Json)
  FieldObject(Map[String, FieldNode])
  FieldList(Array[FieldNode])
}

///|
fn parse_field_path(source : String) -> Result[Array[FieldPart], String] {
  guard !source.is_empty() else { return Err("field name cannot be empty") }
  let parts : Array[FieldPart] = []
  let mut cursor = 0
  while cursor < source.length() && source[cursor] != '[' {
    cursor += 1
  }
  guard cursor > 0 else {
    return Err("field name must start with an object key")
  }
  parts.push(FieldKey(source[:cursor].to_owned()))
  while cursor < source.length() {
    guard source[cursor] == '[' else { return Err("malformed field path") }
    cursor += 1
    let start = cursor
    while cursor < source.length() && source[cursor] != ']' {
      guard source[cursor] != '[' else { return Err("malformed field path") }
      cursor += 1
    }
    guard cursor < source.length() else { return Err("malformed field path") }
    let name = source[start:cursor].to_owned()
    if name.is_empty() {
      parts.push(FieldArray)
    } else {
      guard !name.iter().any(ch => ch.to_int() < 32 || ch.to_int() == 127) else {
        return Err("malformed field path")
      }
      parts.push(FieldKey(name))
    }
    cursor += 1
    guard cursor == source.length() || source[cursor] == '[' else {
      return Err("malformed field path")
    }
  }
  // Consecutive [] selectors are equivalent to one array in gh's request
  // field grammar; retaining them would create an ambiguous array-of-array
  // shape for scalar values.
  let normalized : Array[FieldPart] = []
  for part in parts {
    if part is FieldArray && normalized.last() is Some(FieldArray) {
      continue
    }
    normalized.push(part)
  }
  Ok(normalized)
}

///|
fn node_from_parts(
  parts : Array[FieldPart],
  value : Json,
) -> Result[FieldNode, String] {
  guard !parts.is_empty() else { return Err("field name cannot be empty") }
  let mut node = FieldValue(value)
  for index = parts.length() - 1; index >= 0; index = index - 1 {
    match parts[index] {
      FieldKey(key) => {
        let object : Map[String, FieldNode] = Map([])
        object[key] = node
        node = FieldObject(object)
      }
      FieldArray => node = FieldList([node])
    }
    if index == 0 {
      break
    }
  }
  Ok(node)
}

///|
fn insert_node(
  existing : FieldNode,
  incoming : FieldNode,
) -> Result[FieldNode, String] {
  match (existing, incoming) {
    (FieldObject(left), FieldObject(right)) => {
      for (key, value) in right {
        match left.get(key) {
          None => left[key] = value
          Some(previous) =>
            match insert_node(previous, value) {
              Ok(merged) => left[key] = merged
              Err(_) =>
                return Err(
                  "unexpected override existing field under \"" + key + "\"",
                )
            }
        }
      }
      Ok(FieldObject(left))
    }
    (FieldList(left), FieldList(right)) => {
      for value in right {
        match left.last() {
          Some(FieldObject(_)) =>
            match insert_node(left[left.length() - 1], value) {
              Ok(merged) => left[left.length() - 1] = merged
              Err(_) => left.push(value)
            }
          _ => left.push(value)
        }
      }
      Ok(FieldList(left))
    }
    (FieldValue(_), FieldValue(_)) => Err("unexpected override existing field")
    (FieldValue(_), _) => Err("expected map type under field, got scalar")
    (FieldObject(_), _) => Err("expected array type under field, got map")
    (FieldList(_), _) => Err("expected map type under field, got array")
  }
}

///|
fn node_to_json(node : FieldNode) -> Json {
  match node {
    FieldValue(value) => value
    FieldObject(values) => {
      let output : Map[String, Json] = Map([])
      for (key, value) in values {
        output[key] = node_to_json(value)
      }
      Json::object(output)
    }
    FieldList(values) => Json::array(values.map(node_to_json))
  }
}

///|
/// Build nested `-f/--field` input into a JSON object. Object members merge;
/// duplicate scalar members are rejected. Arrays of objects merge into the
/// most recent object until a conflicting leaf requires a new object. Entries
/// named in `empty_arrays` are applied after `values`, matching gh's explicit
/// empty-array override behavior.
pub fn build_fields(
  values : Array[(String, Json)],
  empty_arrays : Array[String],
) -> Result[Map[String, Json], String] {
  let mut root = FieldObject(Map([]))
  for (name, value) in values {
    let parts = match parse_field_path(name) {
      Ok(parts) => parts
      Err(error) => return Err(error)
    }
    let incoming = match node_from_parts(parts, value) {
      Ok(node) => node
      Err(error) => return Err(error)
    }
    root = match insert_node(root, incoming) {
      Ok(node) => node
      Err(error) => return Err(error)
    }
  }
  for name in empty_arrays {
    let target = name.strip_suffix("[]").unwrap_or(name).to_owned()
    let parts = match parse_field_path(target) {
      Ok(parts) => parts
      Err(error) => return Err(error)
    }
    guard parts.last() is Some(FieldKey(_)) else {
      return Err("empty array name must select an object field")
    }
    let incoming = FieldList([])
    let mut wrapped = incoming
    for index = parts.length() - 1; index >= 0; index = index - 1 {
      match parts[index] {
        FieldKey(key) => {
          let object : Map[String, FieldNode] = Map([])
          object[key] = wrapped
          wrapped = FieldObject(object)
        }
        FieldArray => return Err("empty array name must select an object field")
      }
      if index == 0 {
        break
      }
    }
    root = match insert_empty_array(root, wrapped) {
      Ok(node) => node
      Err(error) => return Err(error)
    }
  }
  match root {
    FieldObject(values) => {
      let output : Map[String, Json] = Map([])
      for (key, value) in values {
        output[key] = node_to_json(value)
      }
      Ok(output)
    }
    _ => Err("field root must be an object")
  }
}

///|
fn insert_empty_array(
  existing : FieldNode,
  incoming : FieldNode,
) -> Result[FieldNode, String] {
  match (existing, incoming) {
    (FieldObject(left), FieldObject(right)) => {
      for (key, value) in right {
        match left.get(key) {
          None => left[key] = value
          Some(FieldObject(_)) =>
            match insert_empty_array(left[key], value) {
              Ok(merged) => left[key] = merged
              Err(error) => return Err(error)
            }
          Some(_) => left[key] = value
        }
      }
      Ok(FieldObject(left))
    }
    _ => Err("cannot set empty array under scalar")
  }
}

///|
fn append_query_field(
  output : Array[(String, String)],
  key : String,
  value : Json,
) -> Unit {
  match value {
    Array(items) =>
      for item in items {
        append_query_field(output, key + "[]", item)
      }
    Object(fields) =>
      for name, item in fields {
        append_query_field(output, key + "[" + name + "]", item)
      }
    String(text) => output.push((key, text))
    Null => output.push((key, ""))
    _ => output.push((key, value.stringify()))
  }
}

///|
test "typed API field conversion preserves integer boundaries" {
  assert_eq(
    typed_field("9223372036854775807").stringify(),
    "9223372036854775807",
  )
  assert_eq(
    typed_field("9223372036854775808"),
    Json::string("9223372036854775808"),
  )
  assert_eq(typed_field("3.5"), Json::string("3.5"))
  assert_eq(typed_field("true"), Json::boolean(true))
  assert_eq(typed_field("null"), Json::null())
}
