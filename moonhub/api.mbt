///|
/// A schema-independent JSON response. data is the entire server JSON value,
/// including any envelope. Only validated correlation and ETag headers escape
/// the raw transport boundary.
pub struct ApiResponse {
  status : Int
  data : Json
  etag : EntityTag?
  request_id : String?
}

///|
/// A generic request result. Reads have no mutation outcome; every other
/// supported method carries the same conservative outcome policy as typed
/// writes. Observer failures do not replace the HTTP result.
pub struct ApiResult {
  value : Result[ApiResponse, @gh.ApiFailure]
  trace_failed : Bool
  outcome : MutationOutcome?
}

///|
/// Generic headers can customize an endpoint without replacing the client's
/// origin, credentials, HTTP framing, JSON representation, or selected method.
fn valid_api_headers(headers : Array[(String, String)]) -> Bool {
  if headers.length() > 32 || !allowed_headers(headers) {
    return false
  }
  let mut remaining = 8192
  for (name, value) in headers {
    if name.length() > 128 ||
      value.length() > 4096 ||
      name.length() + value.length() > remaining ||
      !value.iter().all(character => character.to_int() <= 126) {
      return false
    }
    remaining -= name.length() + value.length()
    let name = name.to_lower()
    if name.has_prefix("x-forwarded-") {
      return false
    }
    match name {
      "te"
      | "trailer"
      | "keep-alive"
      | "forwarded"
      | "x-http-method-override"
      | "x-http-method"
      | "x-method-override"
      | "x-original-url"
      | "x-rewrite-url"
      | "cookie2"
      | "api-key"
      | "x-api-key"
      | "x-auth-token"
      | "x-access-token" => return false
      "accept" | "content-type" if value != "application/json" => return false
      "if-match" => if EntityTag::parse(value) is Err(_) { return false }
      _ => ()
    }
  }
  true
}

///|
/// Validate the generic JSON API boundary without sending or recording an
/// attempt. Paths are relative to the SDK's /api/v1 prefix; absolute URLs and
/// already-prefixed paths are rejected. An absent body differs from JSON null.
/// Request JSON is validated with the standard parser and sent unchanged, so
/// parsing cannot round large integers or rewrite whitespace on the wire.
///
/// ```mbt check
/// test {
///   let request = @gh.Request::new(
///     verb=@gh.Post,
///     path="/extensions/jobs",
///     body="null",
///   )
///   assert_true(@moonhub.validate_api_request(request) is Ok(_))
///   assert_true(
///     @moonhub.validate_api_request(
///       @gh.Request::new(verb=@gh.Get, path="/user", body="null"),
///     )
///     is Err(_),
///   )
/// }
/// ```
pub fn validate_api_request(
  request : @gh.Request,
) -> Result[Unit, @gh.ApiError] {
  if request.path.length() > 4096 ||
    !@gh.valid_request_path(request.path) ||
    request.path == "/api/v1" ||
    request.path.has_prefix("/api/v1/") ||
    request.path.has_prefix("/api/v1?") {
    return Err(
      @gh.InvalidRequest(
        message="expected an SDK-relative API path within 4096 characters",
      ),
    )
  }
  if !valid_api_headers(request.headers) {
    return Err(
      @gh.InvalidRequest(message="invalid or reserved JSON API request header"),
    )
  }
  if request.body is Some(body) {
    if request.verb is @gh.Get {
      return Err(@gh.InvalidRequest(message="GET requests cannot have a body"))
    }
    if body.length() > 80000 || @utf8.encode(body).length() > 80000 {
      return Err(
        @gh.InvalidRequest(message="API JSON body exceeds 80000 UTF-8 bytes"),
      )
    }
    ignore(@wire_json.parse(body)) catch {
      _ =>
        return Err(
          @gh.InvalidRequest(
            message="API body must contain one complete JSON value",
          ),
        )
    }
  }
  Ok(())
}

///|
/// Send one JSON API request without redirects, pagination, preflight reads or
/// retries, including for GET. Use typed operations when their response schema
/// and retry policy are wanted. A successful empty 204/205 yields JSON null;
/// every other successful response must contain a complete JSON value.
pub async fn Client::api(
  self : Client,
  request : @gh.Request,
  operation_id~ : String,
) -> ApiResult {
  let write = !(request.verb is @gh.Get)
  if validate_api_request(request) is Err(error) {
    return {
      value: Err(@gh.ApiFailure::new(kind=error)),
      trace_failed: false,
      outcome: if write {
        Some(NotSent)
      } else {
        None
      },
    }
  }
  let call = self.execute(request, operation_id~)
  let response = match call.response {
    Ok(response) => response
    Err(error) =>
      return {
        value: Err(error),
        trace_failed: call.trace_failed,
        outcome: if write {
          Some(mutation_failure_outcome(error))
        } else {
          None
        },
      }
  }
  let failure = fn(message : String) -> ApiResult {
    {
      value: Err(self.read_failure(response, message)),
      trace_failed: call.trace_failed,
      outcome: if write {
        Some(Unknown)
      } else {
        None
      },
    }
  }
  let etag = match response_etag(response) {
    Ok(etag) => etag
    Err(_) => return failure("invalid or repeated response ETag")
  }
  let data = if response.status is (204 | 205) {
    if !response.body.is_empty() {
      return failure("204 and 205 API responses must have an empty body")
    }
    Json::null()
  } else {
    @wire_json.parse(response.body) catch {
      _ => return failure("API response must contain one complete JSON value")
    }
  }
  {
    value: Ok({
      status: response.status,
      data,
      etag,
      request_id: self.response_request_id(response),
    }),
    trace_failed: call.trace_failed,
    outcome: if !write {
      None
    } else if response.status == 202 {
      Some(Accepted)
    } else {
      Some(Applied)
    },
  }
}
