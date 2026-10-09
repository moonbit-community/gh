///|
/// Validated AND filters for local diagnostic history. Results contain the
/// latest matching records, retaining their original order in the file.
pub struct TraceQuery {
  operation_id : String?
  request_id : String?
  status : Int?
  verb : HttpMethod?
  path_prefix : String?
  limit : Int
}

///|
pub fn TraceQuery::new(
  operation_id? : String,
  request_id? : String,
  status? : Int,
  verb? : HttpMethod,
  path_prefix? : String,
  limit? : Int = 100,
) -> Result[TraceQuery, ApiError] {
  if limit < 1 || limit > 1000 {
    return Err(InvalidRequest(message="trace limit must be between 1 and 1000"))
  }
  for identifier in [operation_id, request_id] {
    if identifier is Some(value) && trace_identifier(value, []) is None {
      return Err(InvalidRequest(message="invalid trace identifier filter"))
    }
  }
  if status is Some(value) && (value < 100 || value > 599) {
    return Err(InvalidRequest(message="invalid trace status filter"))
  }
  if path_prefix is Some(value) &&
    (
      value.contains("?") ||
      value.contains("#") ||
      trace_path(value, []) != value
    ) {
    return Err(InvalidRequest(message="invalid trace path prefix filter"))
  }
  Ok({ operation_id, request_id, status, verb, path_prefix, limit, })
}

///|
pub struct TraceQueryResult {
  records : Array[TraceRecord]
  scanned : Int
  matched : Int
  truncated : Bool
  incomplete_tail : Bool
}

///|
/// Stable JSON output. Only the existing trace metadata schema is serialized;
/// unknown input fields, credentials, headers and bodies cannot be forwarded.
pub fn TraceQueryResult::to_json(self : TraceQueryResult) -> Json {
  let records = self.records.map(record => record.to_json())
  {
    "version": 1,
    "data": Json::array(records),
    "scan": {
      "scanned": self.scanned.to_json(),
      "matched": self.matched.to_json(),
      "truncated": self.truncated.to_json(),
      "incomplete_tail": self.incomplete_tail.to_json(),
    },
  }
}

///|
fn TraceQuery::matches(self : TraceQuery, record : TraceRecord) -> Bool {
  if self.operation_id is Some(value) && value != record.operation_id {
    return false
  }
  if self.request_id is Some(value) && record.request_id != Some(value) {
    return false
  }
  if self.status is Some(value) && record.status != Some(value) {
    return false
  }
  if self.verb is Some(value) && value.as_string() != record.verb.as_string() {
    return false
  }
  if self.path_prefix is Some(value) && !record.path.has_prefix(value) {
    return false
  }
  true
}

///|
fn[T] invalid_trace_record() -> T raise {
  fail("invalid trace record")
}

///|
fn trace_string(fields : Map[String, Json], key : String) -> String raise {
  match fields.get(key) {
    Some(String(value)) => value
    _ => invalid_trace_record()
  }
}

///|
fn trace_nullable_string(
  fields : Map[String, Json],
  key : String,
) -> String? raise {
  match fields.get(key) {
    Some(String(value)) => Some(value)
    Some(Null) => None
    _ => invalid_trace_record()
  }
}

///|
fn trace_integer(value : Json, minimum : Int64, maximum : Int64) -> Int64 raise {
  guard @wire_json.integer(value, minimum~, maximum~) is Some(integer) else {
    invalid_trace_record()
  }
  integer
}

///|
fn trace_field(fields : Map[String, Json], key : String) -> Json raise {
  match fields.get(key) {
    Some(value) => value
    None => invalid_trace_record()
  }
}

///|
fn decode_trace_record(
  line : StringView,
  secrets : Array[String],
) -> TraceRecord raise {
  guard line.length() <= 16384 else { invalid_trace_record() }
  guard @wire_json.parse(line) is Object(fields) else { invalid_trace_record() }
  guard trace_integer(trace_field(fields, "version"), 1, 1) == 1 else {
    invalid_trace_record()
  }
  let verb = match trace_string(fields, "method") {
    "GET" => Get
    "POST" => Post
    "PUT" => Put
    "PATCH" => Patch
    "DELETE" => Delete
    _ => invalid_trace_record()
  }
  let status = match trace_field(fields, "status") {
    Null => None
    value => Some(trace_integer(value, 100, 599).to_int())
  }
  let duration_ms = match trace_field(fields, "duration_ms") {
    Null => None
    value => Some(trace_integer(value, 0, 9007199254740991))
  }
  let request_id = trace_nullable_string(fields, "request_id")
  let error_code = trace_nullable_string(fields, "error_code")
  TraceRecord::new(
    operation_id=trace_string(fields, "operation_id"),
    attempt=trace_integer(trace_field(fields, "attempt"), 1, 2147483647).to_int(),
    verb~,
    path=trace_string(fields, "path"),
    status?,
    duration_ms?,
    request_id?,
    error_code?,
  ).redacted(secrets~)
}

///|
/// Scan version-1 JSONL diagnostic history, with bounded memory and input.
/// All complete lines are validated even after the result limit is reached.
/// A final unterminated line is omitted and flagged, including valid JSON:
/// append completion is defined by the newline written by the recorder.
/// Invalid complete lines fail the whole query without partial results.
/// The pure decoder caps input at 8 Mi UTF-16 units and each line at 16 Ki;
/// the native file adapter additionally enforces an 8 MiB byte limit.
pub fn parse_trace_jsonl(
  content : String,
  query? : TraceQuery,
  secrets? : Array[String] = [],
) -> Result[TraceQueryResult, ApiError] {
  if content.length() > 8388608 {
    return Err(Decode(message="trace input exceeds its size limit"))
  }
  let query = match query {
    Some(query) => query
    None =>
      {
        operation_id: None,
        request_id: None,
        status: None,
        verb: None,
        path_prefix: None,
        limit: 100,
      }
  }
  let records : Array[TraceRecord] = []
  let incomplete_tail = !content.is_empty() && !content.has_suffix("\n")
  let mut scanned = 0
  let mut matched = 0
  let mut cursor = 0
  let mut position = 0
  for line in content.split("\n") {
    if line.length() > 16384 {
      return Err(Decode(message="trace input exceeds its line limit"))
    }
    position += line.length()
    if position == content.length() {
      break
    }
    position += 1
    let record = decode_trace_record(line, secrets) catch {
      _ =>
        return Err(
          Decode(message="trace input contains an invalid complete record"),
        )
    }
    scanned += 1
    if query.matches(record) {
      matched += 1
      if records.length() < query.limit {
        records.push(record)
      } else {
        records[cursor] = record
        cursor = (cursor + 1) % query.limit
      }
    }
  }
  let ordered = if matched > query.limit {
    records[cursor:].to_owned() + records[:cursor].to_owned()
  } else {
    records
  }
  Ok({
    records: ordered,
    scanned,
    matched,
    truncated: matched > query.limit,
    incomplete_tail,
  })
}
