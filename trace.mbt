///|
/// Metadata for one completed transport attempt. Construction alone does not
/// sanitize untrusted values; use `redacted` before observing a record or
/// `to_json_line` before persisting it. Request bodies and headers are absent.
pub struct TraceRecord {
  operation_id : String
  attempt : Int
  verb : HttpMethod
  path : String
  status : Int?
  duration_ms : Int64?
  request_id : String?
  error_code : String?
}

///|
pub fn TraceRecord::new(
  operation_id~ : String,
  attempt~ : Int,
  verb~ : HttpMethod,
  path~ : String,
  status? : Int,
  duration_ms? : Int64,
  request_id? : String,
  error_code? : String,
) -> TraceRecord {
  {
    operation_id,
    attempt,
    verb,
    path,
    status,
    duration_ms,
    request_id,
    error_code,
  }
}

///|
fn trace_has_secret(value : String, secrets : Array[String]) -> Bool {
  secrets.any(secret => !secret.is_empty() && value.contains(secret))
}

///|
fn trace_identifier(value : String, secrets : Array[String]) -> String? {
  if value.is_empty() ||
    value.length() > 128 ||
    trace_has_secret(value, secrets) {
    return None
  }
  for character in value {
    match character {
      'a'..='z' | 'A'..='Z' | '0'..='9' | '-' | '_' | '.' => ()
      _ => return None
    }
  }
  Some(value)
}

///|
fn trace_path(value : String, secrets : Array[String]) -> String {
  // Query values and fragments have no place in the initial trace format.
  let path = value.split("?").next().unwrap_or("").to_owned()
  let path = path.split("#").next().unwrap_or("").to_owned()
  if !path.has_prefix("/") ||
    path.has_prefix("//") ||
    path.length() > 2048 ||
    path.contains("%") {
    // Conservatively hide percent-encoded paths: a token may be encoded with
    // any mixture of raw and escaped bytes. We do not decode URL syntax here.
    return "[redacted]"
  }
  for character in path {
    if character < ' ' || character == '\u{7f}' {
      return "[redacted]"
    }
  }
  let mut redacted = path
  for secret in secrets {
    if !secret.is_empty() {
      redacted = redacted.replace_all(old=secret, new="[redacted]")
      if redacted.length() > 2048 {
        return "[redacted]"
      }
    }
  }
  redacted
}

///|
fn trace_error_code(value : String) -> String {
  match value {
    "invalid_request"
    | "transport"
    | "unauthorized"
    | "forbidden"
    | "not_found"
    | "conflict"
    | "rate_limited"
    | "server"
    | "decode"
    | "unexpected_status"
    | "cancelled" => value
    _ => "unknown"
  }
}

///|
/// Produce metadata safe for an injected trace observer. Unknown error text,
/// invalid IDs, URLs, encoded paths, query strings, and fragments are removed.
/// Supply every credential known to the caller to hide it in remaining fields.
pub fn TraceRecord::redacted(
  self : TraceRecord,
  secrets? : Array[String] = [],
) -> TraceRecord {
  {
    operation_id: trace_identifier(self.operation_id, secrets).unwrap_or(
      "redacted",
    ),
    attempt: if self.attempt > 0 {
      self.attempt
    } else {
      1
    },
    verb: self.verb,
    path: trace_path(self.path, secrets),
    status: match self.status {
      Some(status) if status >= 100 && status <= 599 => Some(status)
      _ => None
    },
    duration_ms: match self.duration_ms {
      Some(duration) if duration >= 0 && duration <= 9007199254740991 =>
        Some(duration)
      _ => None
    },
    request_id: match self.request_id {
      Some(value) => trace_identifier(value, secrets)
      None => None
    },
    error_code: self.error_code.map(trace_error_code),
  }
}

///|
/// Encode one sanitized metadata object. This is the final sanitization
/// boundary even for directly constructed records. Bodies, arbitrary headers
/// and error messages cannot enter this format.
pub fn TraceRecord::to_json(
  self : TraceRecord,
  secrets? : Array[String] = [],
) -> Json {
  let record = self.redacted(secrets~)
  {
    "version": 1,
    "operation_id": record.operation_id.to_json(),
    "attempt": record.attempt.to_json(),
    "method": record.verb.as_string().to_json(),
    "path": record.path.to_json(),
    "status": match record.status {
      Some(status) => status.to_json()
      None => Json::null()
    },
    "duration_ms": match record.duration_ms {
      Some(duration) => duration.to_double().to_json()
      None => Json::null()
    },
    "request_id": match record.request_id {
      Some(request_id) => request_id.to_json()
      None => Json::null()
    },
    "error_code": match record.error_code {
      Some(error_code) => error_code.to_json()
      None => Json::null()
    },
  }
}

///|
/// Serialize exactly one sanitized JSONL record, including its final newline.
pub fn TraceRecord::to_json_line(
  self : TraceRecord,
  secrets? : Array[String] = [],
) -> String {
  self.to_json(secrets~).stringify() + "\n"
}
