///|
/// Decode the proposed MoonHub v1 error envelope. Status is authoritative;
/// malformed/HTML errors retain the HTTP category. Server prose and unknown
/// codes are intentionally not surfaced because they can echo credentials.
pub fn decode_response(
  response : @gh.Response,
  secrets? : Array[String] = [],
) -> Result[@gh.Response, @gh.ApiFailure] {
  if response.status >= 200 && response.status < 300 {
    return Ok(response)
  }
  let mut code : String? = None
  let mut body_id : String? = None
  let json = @wire_json.parse(response.body) catch { _ => Json::null() }
  if json is { "version": version, "error": Object(error), .. } &&
    @wire_json.integer(version, minimum=1, maximum=1) is Some(_) {
    if error.get("code") is Some(String(value)) && recognized_error_code(value) {
      code = Some(value)
    }
    if json is { "request_id": String(value), .. } {
      body_id = safe_request_id(value)
    }
  }
  let request_id = match response.header("x-request-id") {
    Some(value) => safe_request_id(value)
    None => body_id
  }
  let request_id = match request_id {
    Some(value) if secrets.any(secret => {
        !secret.is_empty() && value.contains(secret)
      }) => None
    other => other
  }
  let kind = @gh.api_error_for_status(
    status=response.status,
    message="MoonHub rejected the request",
  )
  Err(@gh.ApiFailure::new(kind~, status=response.status, code?, request_id?))
}

///|
fn recognized_error_code(code : String) -> Bool {
  match code {
    "invalid_request"
    | "unauthorized"
    | "forbidden"
    | "not_found"
    | "conflict"
    | "precondition_failed"
    | "rate_limited"
    | "internal_error"
    | "limit_exceeded"
    | "unsupported_capability" => true
    _ => false
  }
}

///|
fn safe_request_id(value : String) -> String? {
  if !value.is_empty() &&
    value.length() <= 128 &&
    value
    .iter()
    .all(ch => {
      ch is ('a'..='z' | 'A'..='Z' | '0'..='9') || "._-".contains_char(ch)
    }) {
    Some(value)
  } else {
    None
  }
}
