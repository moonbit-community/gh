///|
/// HTTP outcome plus independent observability status. A sink failure must not
/// turn a completed mutation into a retryable transport failure.
pub struct CallResult {
  response : Result[@gh.Response, @gh.ApiFailure]
  trace_failed : Bool
}

///|
/// Dependencies are explicit. Constructing a client does not read environment
/// variables or files, nor does it connect to the server.
pub struct Client {
  priv config : ClientConfig
  priv transport : @gh.Transport
  priv token : Token?
  priv trace : (async (@gh.TraceRecord) -> Unit)?
  priv clock : () -> Int64
  priv read_retry : ReadRetryPolicy
  priv retry_wait : async (Int) -> Unit
}

///|
/// Transport and credentials must belong to the same canonical origin.
pub fn Client::new(
  config~ : ClientConfig,
  transport~ : @gh.Transport,
  token? : Token,
  trace? : async (@gh.TraceRecord) -> Unit,
  clock? : () -> Int64 = @async.now,
  read_retry? : ReadRetryPolicy = ReadRetryPolicy::default(),
  retry_wait? : async (Int) -> Unit = @async.sleep,
) -> Result[Client, @gh.ApiError] {
  let origin = match @gh.normalize_origin(config.base_url) {
    Ok(origin) => origin
    Err(err) => return Err(err)
  }
  guard @gh.normalize_origin(transport.origin) is Ok(bound) && origin == bound else {
    return Err(
      @gh.InvalidRequest(message="transport origin does not match client"),
    )
  }
  if token is Some(token) && token.origin() != origin {
    return Err(@gh.InvalidRequest(message="token origin does not match client"))
  }
  Ok({
    config: ClientConfig::new(base_url=origin),
    transport,
    token,
    trace,
    clock,
    read_retry,
    retry_wait,
  })
}

///|
fn Client::secrets(self : Client) -> Array[String] {
  match self.token {
    Some(token) => {
      let authorization = token.authorization()
      [
        authorization,
        authorization.strip_prefix("Bearer ").unwrap_or("").to_owned(),
      ]
    }
    None => []
  }
}

///|
fn allowed_headers(headers : Array[(String, String)]) -> Bool {
  let seen : Map[String, Unit] = Map([])
  for (key, value) in headers {
    guard !key.is_empty() &&
      key.iter().all(ch => ch is ('a'..='z' | 'A'..='Z' | '0'..='9' | '-')) &&
      value.iter().all(ch => ch.to_int() >= 32 && ch.to_int() != 127) else {
      return false
    }
    let name = key.to_lower()
    if seen.contains(name) {
      return false
    }
    seen[name] = ()
    match name {
      "authorization"
      | "proxy-authorization"
      | "cookie"
      | "host"
      | "content-length"
      | "transfer-encoding"
      | "connection"
      | "upgrade"
      | "expect"
      | "proxy-connection" => return false
      "accept-encoding" if value != "identity" => return false
      _ => ()
    }
  }
  true
}

///|
fn invalid_call(message : String) -> CallResult {
  {
    response: Err(@gh.ApiFailure::new(kind=@gh.InvalidRequest(message~))),
    trace_failed: false,
  }
}

///|
async fn Client::record(self : Client, record : @gh.TraceRecord) -> Bool {
  if self.trace is Some(write) {
    // Once a response exists, an observer must not lose it through a stuck
    // lock or cancellation. Protect only this bounded completion operation.
    return @async.protect_from_cancel(() => {
      @async.with_timeout(1000, () => {
        write(record.redacted(secrets=self.secrets()))
        true
      }) catch {
        _ => false
      }
    })
  }
  true
}

///|
/// Send exactly one attempt. path is relative to /api/v1 (e.g. /user).
/// operation_id is supplied by the caller and may span future pagination or
/// retry attempts. No retry, redirect or pagination is performed here.
pub async fn Client::execute(
  self : Client,
  request : @gh.Request,
  operation_id~ : String,
  attempt? : Int = 1,
) -> CallResult {
  self.execute_attempt(request, operation_id~, attempt~).0
}

///|
async fn Client::execute_attempt(
  self : Client,
  request : @gh.Request,
  operation_id~ : String,
  attempt~ : Int,
) -> (CallResult, RetryAfter) {
  guard attempt > 0 && safe_request_id(operation_id) is Some(_) else {
    return (
      invalid_call("operation_id and a positive attempt are required"),
      Stop,
    )
  }
  guard @gh.valid_request_path(request.path) && allowed_headers(request.headers) else {
    return (invalid_call("invalid API path or reserved request header"), Stop)
  }
  let path = self.config.api_prefix + request.path
  let headers = request.headers.copy()
  if !headers.any(pair => pair.0.equal_ignore_ascii_case("accept")) {
    headers.push(("Accept", "application/json"))
  }
  if request.body is Some(_) &&
    !headers.any(pair => pair.0.equal_ignore_ascii_case("content-type")) {
    headers.push(("Content-Type", "application/json"))
  }
  if self.token is Some(token) {
    headers.push(("Authorization", token.authorization()))
  }
  let started = (self.clock)()
  let body = request.body
  let response = self.transport.send(
    @gh.Request::new(verb=request.verb, path~, body?, headers~),
  ) catch {
    err if @async.is_cancellation_error(err) => {
      let elapsed = (self.clock)() - started
      // Cancellation still produces a best-effort completion record; preserve
      // the original cancellation and bound time spent in a failing observer.
      ignore(
        self.record(
          @gh.TraceRecord::new(
            operation_id~,
            attempt~,
            verb=request.verb,
            path~,
            duration_ms=elapsed,
            error_code="cancelled",
          ),
        ),
      )
      raise err
    }
    _ => {
      let elapsed = (self.clock)() - started
      let trace_ok = self.record(
        @gh.TraceRecord::new(
          operation_id~,
          attempt~,
          verb=request.verb,
          path~,
          duration_ms=elapsed,
          error_code="transport",
        ),
      )
      return (
        {
          response: Err(
            @gh.ApiFailure::new(
              kind=@gh.Transport(
                message="request did not complete; remote outcome may be unknown",
              ),
            ),
          ),
          trace_failed: !trace_ok,
        },
        Absent,
      )
    }
  }
  let elapsed = (self.clock)() - started
  let decoded = decode_response(response, secrets=self.secrets())
  let error_code = match decoded {
    Ok(_) => None
    Err(err) => Some(err.kind.code())
  }
  let request_id = match decoded {
    Err(err) => err.request_id
    Ok(_) => response.header("x-request-id")
  }
  let trace_ok = self.record(
    @gh.TraceRecord::new(
      operation_id~,
      attempt~,
      verb=request.verb,
      path~,
      status=response.status,
      duration_ms=elapsed,
      request_id?,
      error_code?,
    ),
  )
  (
    { response: decoded, trace_failed: !trace_ok, },
    retry_after(response, self.read_retry.max_delay_ms),
  )
}
