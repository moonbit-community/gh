///|
/// Request metadata. Call `redacted` before observing, and `to_json_line`
/// before persistence: both boundaries independently remove secret material.
pub struct TraceRecord {
  provider : String
  host : String
  operation_name : String
  operation_id : String
  attempt : Int32
  verb : String
  path : String
  status : Int32?
  duration_ms : Int64?
  request_id : String?
  error_code : String?
  query_fingerprint : String?
}

///|
pub fn TraceRecord::new(
  host~ : String,
  operation_name~ : String,
  operation_id~ : String,
  attempt~ : Int32,
  verb~ : String,
  path~ : String,
  status? : Int32,
  duration_ms? : Int64,
  request_id? : String,
  error_code? : String,
  query_fingerprint? : String,
) -> TraceRecord {
  {
    provider: "github",
    host,
    operation_name,
    operation_id,
    attempt,
    verb,
    path,
    status,
    duration_ms,
    request_id,
    error_code,
    query_fingerprint,
  }
}

///|
fn trace_secret(value : String, secrets : Array[String]) -> Bool {
  secrets.any(secret => !secret.is_empty() && value.contains(secret))
}

///|
fn trace_identifier(value : String, secrets : Array[String]) -> String? {
  if value.is_empty() ||
    value.length() > 128 ||
    trace_secret(value, secrets) ||
    !value
    .iter()
    .all(ch => ch is ('a'..<='z' | 'A'..<='Z' | '0'..<='9' | '-' | '_' | '.')) {
    None
  } else {
    Some(value)
  }
}

///|
pub fn TraceRecord::redacted(
  self : TraceRecord,
  secrets~ : Array[String] = [],
) -> TraceRecord {
  let path = self.path.split("?").next().unwrap_or("").to_owned()
  let path = path.split("#").next().unwrap_or("").to_owned()
  let path = if !valid_path(path) ||
    path.contains_char('%') ||
    path.length() > 2048 ||
    trace_secret(path, secrets) {
    "[redacted]"
  } else {
    path
  }
  let host = if !trace_secret(self.host, secrets) &&
    parse_endpoint("https://" + self.host) is Some(endpoint) &&
    endpoint.path == "/" {
    endpoint.authority
  } else {
    "redacted"
  }
  {
    provider: "github",
    host,
    operation_name: trace_identifier(self.operation_name, secrets).unwrap_or(
      "unknown",
    ),
    operation_id: trace_identifier(self.operation_id, secrets).unwrap_or(
      "redacted",
    ),
    attempt: if self.attempt > 0 {
      self.attempt
    } else {
      1
    },
    verb: if valid_method(self.verb) && !trace_secret(self.verb, secrets) {
      self.verb
    } else {
      "UNKNOWN"
    },
    path,
    status: match self.status {
      Some(value) if value >= 100 && value <= 599 => Some(value)
      _ => None
    },
    duration_ms: match self.duration_ms {
      Some(value) if value >= 0 && value <= 9007199254740991L => Some(value)
      _ => None
    },
    request_id: match self.request_id {
      Some(value) => trace_identifier(value, secrets)
      None => None
    },
    error_code: self.error_code.map(value => {
      match value {
        "invalid_configuration"
        | "invalid_request"
        | "transport"
        | "authentication"
        | "permission"
        | "rate_limited"
        | "http"
        | "decode"
        | "graphql"
        | "cancelled" => value
        _ => "unknown"
      }
    }),
    query_fingerprint: match self.query_fingerprint {
      Some(value) if value.has_prefix("shape-v1-") &&
        value.length() == 73 &&
        value[9:].iter().all(ch => ch is ('0'..<='9' | 'a'..<='f')) &&
        !trace_secret(value, secrets) => Some(value)
      _ => None
    },
  }
}

///|
pub fn TraceRecord::to_json(
  self : TraceRecord,
  secrets~ : Array[String] = [],
) -> Json {
  let record = self.redacted(secrets~)
  {
    "version": 1,
    "provider": "github",
    "host": record.host,
    "operation_name": record.operation_name,
    "operation_id": record.operation_id,
    "attempt": Json(record.attempt),
    "method": record.verb,
    "path": record.path,
    "status": record.status.map_or(Json::null(), value => Json(value)),
    "duration_ms": record.duration_ms.map_or(Json::null(), value => Json(value)),
    "request_id": record.request_id.map_or(Json::null(), value => Json(value)),
    "error_code": record.error_code.map_or(Json::null(), value => Json(value)),
    "query_fingerprint": record.query_fingerprint.map_or(Json::null(), value => {
      Json(value)
    }),
  }
}

///|
pub fn TraceRecord::to_json_line(
  self : TraceRecord,
  secrets~ : Array[String] = [],
) -> String {
  self.to_json(secrets~).stringify() + "\n"
}

///|
/// Fingerprint only the syntax shape: all names, strings, numbers, comments
/// and whitespace are removed before SHA-256. Consequently changing a token,
/// literal, alias, enum value or operation name cannot be tested against this
/// fingerprint. It is deliberately not an identity for a GraphQL document.
pub fn graphql_query_fingerprint(query : String) -> String {
  if query.length() > 1048576 {
    return "invalid"
  }
  let shape = StringBuilder()
  let mut cursor = 0
  while cursor < query.length() {
    let ch = query[cursor]
    if ch == ' ' || ch == '\r' || ch == '\n' || ch == '\t' || ch == ',' {
      cursor += 1
    } else if ch == '#' {
      while cursor < query.length() && query[cursor] != '\n' {
        cursor += 1
      }
    } else if ch == '"' {
      let block = cursor + 2 < query.length() &&
        query[cursor:cursor + 3] == "\"\"\""
      cursor += if block { 3 } else { 1 }
      let mut closed = false
      while cursor < query.length() {
        if query[cursor] == '\\' {
          cursor += 2
          continue
        }
        if block &&
          cursor + 2 < query.length() &&
          query[cursor:cursor + 3] == "\"\"\"" {
          cursor += 3
          closed = true
          break
        }
        if !block && query[cursor] == '"' {
          cursor += 1
          closed = true
          break
        }
        cursor += 1
      }
      if !closed {
        return "invalid"
      }
      shape.write_string("V")
    } else if ch is ('a'..<='z' | 'A'..<='Z' | '_') {
      while cursor < query.length() &&
            query[cursor] is ('a'..<='z' | 'A'..<='Z' | '0'..<='9' | '_') {
        cursor += 1
      }
      shape.write_string("N")
    } else if ch is ('0'..<='9' | '-') {
      while cursor < query.length() &&
            query[cursor] is ('0'..<='9' | '-' | '+' | '.' | 'e' | 'E') {
        cursor += 1
      }
      shape.write_string("V")
    } else if ch
      is ('!'
      | '$'
      | '&'
      | '('
      | ')'
      | ':'
      | '='
      | '@'
      | '['
      | ']'
      | '{'
      | '}'
      | '|'
      | '.') {
      shape.write_string(query[cursor:cursor + 1].to_owned())
      cursor += 1
    } else {
      return "invalid"
    }
  }
  let digest = @crypto.sha256(@utf8.encode(shape.to_string()))
  let result = StringBuilder()
  result.write_string("shape-v1-")
  let hex = "0123456789abcdef"
  for byte in digest {
    result.write_char(hex.get_char(byte.to_int() / 16).unwrap())
    result.write_char(hex.get_char(byte.to_int() % 16).unwrap())
  }
  result.to_string()
}
