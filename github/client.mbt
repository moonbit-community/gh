///|
/// A raw GitHub REST/GraphQL client. It owns URL construction and GitHub
/// headers while the injected transport owns sockets and platform I/O.
pub struct Client {
  config : ClientConfig
  transport : Transport
  retry_policy : RetryPolicy
  priv trace_observer : (async (TraceRecord) -> Unit)?
  priv clock : () -> Int64
  priv mut observer_failures : Int32
}

///|
pub fn Client::new(
  config~ : ClientConfig,
  transport~ : Transport,
  retry_policy~ : RetryPolicy = RetryPolicy::default(),
  trace_observer? : async (TraceRecord) -> Unit,
  clock~ : () -> Int64 = @async.now,
) -> Result[Client, GitHubError] {
  guard normalized_endpoint(config.base_url) is Some(base_url) else {
    return Err(InvalidConfiguration(message="invalid GitHub REST base URL"))
  }
  match config.graphql_url {
    Some(url) => {
      guard parse_endpoint(url) is Some(endpoint) &&
        parse_endpoint(base_url) is Some(base) &&
        endpoint.origin == base.origin else {
        return Err(
          InvalidConfiguration(
            message="GitHub GraphQL URL must use the configured origin",
          ),
        )
      }
    }
    _ => ()
  }
  guard !config.api_version.is_empty() &&
    config.api_version.iter().all(ch => ch.to_int() > 32 && ch.to_int() < 127) else {
    return Err(InvalidConfiguration(message="invalid GitHub API version"))
  }
  guard !config.user_agent.is_empty() &&
    config.user_agent.iter().all(ch => ch.to_int() >= 32 && ch.to_int() < 127) else {
    return Err(InvalidConfiguration(message="invalid GitHub user agent"))
  }
  if config.token is Some(token) && !valid_token(token) {
    return Err(InvalidConfiguration(message="invalid GitHub token"))
  }
  let trace_observer = match trace_observer {
    Some(observer) => Some(observer)
    None => config.trace_observer
  }
  Ok({
    config: { ..config, base_url, },
    transport,
    retry_policy,
    trace_observer,
    clock,
    observer_failures: 0,
  })
}

///|
/// Cumulative observer failures. They never turn a completed HTTP request
/// into an error or trigger retries.
pub fn Client::trace_failures(self : Client) -> Int32 {
  self.observer_failures
}

///|
/// Send an origin-relative REST request. Successful and unsuccessful HTTP
/// statuses are both handled here: non-2xx statuses become typed errors with
/// the complete raw response retained.
pub async fn Client::request(
  self : Client,
  request : Request,
  operation_id~ : String = "request",
  operation_name~ : String = "rest",
) -> Result[RawResponse, GitHubError] {
  self.send(request, graphql=false, operation_id~, operation_name~)
}

///|
/// Send GraphQL without reconstructing the payload, method or headers. This
/// is the `gh api graphql --input` boundary and returns the full raw envelope.
pub async fn Client::graphql_raw(
  self : Client,
  request : Request,
  operation_id~ : String = "request",
  operation_name~ : String = "graphql",
) -> Result[RawResponse, GitHubError] {
  let query = match request.body {
    Some(body) =>
      try {
        let value = @json.parse(@utf8.decode(body))
        match value {
          { "query": String(query), .. } => Some(query)
          _ => None
        }
      } catch {
        _ => None
      }
    None => None
  }
  let query = match query {
    Some(_) => query
    None => {
      let mut found : String? = None
      for pair in request.query {
        if pair.0 == "query" {
          found = Some(pair.1)
        }
      }
      found
    }
  }
  self.send(
    request,
    graphql=true,
    operation_id~,
    operation_name~,
    query_fingerprint?=query.map(graphql_query_fingerprint),
  )
}

///|
/// A GraphQL request. The response envelope is decoded only after the raw
/// transport has completed, so malformed and empty bodies remain typed errors.
pub async fn Client::graphql(
  self : Client,
  request : GraphQLRequest,
  operation_id~ : String = "request",
) -> Result[GraphQLEnvelope, GitHubError] {
  let payload = request.to_json().stringify()
  let raw_request = Request::new(
    verb=request.verb,
    path=request.path,
    headers=request.headers,
    body=@utf8.encode(payload),
  )
  let response = self.graphql_raw(
    raw_request,
    operation_id~,
    operation_name=request.operation_name.unwrap_or("graphql"),
  )
  let response = match response {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let text = @utf8.decode(response.body) catch {
    _ => return Err(Decode(message="GitHub GraphQL response is not UTF-8"))
  }
  guard !text.is_empty() else {
    return Err(Decode(message="GitHub GraphQL response is empty"))
  }
  let value : Json = @json.parse(text) catch {
    _ => return Err(Decode(message="GitHub GraphQL response is invalid JSON"))
  }
  match value {
    { "errors": Array(errors), "data": data, .. } if errors.length() > 0 =>
      Ok({ response, data: Some(data), errors, })
    { "errors": Array(errors), .. } if errors.length() > 0 =>
      Err(GraphQL(response~, errors~))
    { "data": data, .. } => Ok({ response, data: Some(data), errors: [], })
    _ => Err(Decode(message="GitHub GraphQL response has no data envelope"))
  }
}

///|
async fn Client::send(
  self : Client,
  request : Request,
  graphql~ : Bool,
  operation_id~ : String,
  operation_name~ : String,
  query_fingerprint? : String,
) -> Result[RawResponse, GitHubError] {
  let prepared = self.prepare(request, graphql~)
  match prepared {
    Err(error) => Err(error)
    Ok(request) =>
      self.send_attempts(
        request,
        self.retry_policy.max_attempts(),
        operation_id~,
        operation_name~,
        query_fingerprint?,
      )
  }
}

///|
async fn Client::send_attempts(
  self : Client,
  request : Request,
  max_attempts : Int32,
  operation_id~ : String,
  operation_name~ : String,
  query_fingerprint? : String,
) -> Result[RawResponse, GitHubError] {
  let mut attempt = 1
  for ;; {
    let started = (self.clock)()
    let outcome = self.transport.send(request_copy(request)) catch {
      error if @async.is_being_cancelled() => {
        self.record_attempt(
          request,
          operation_id~,
          operation_name~,
          attempt~,
          started~,
          error_code="cancelled",
          query_fingerprint?,
        )
        raise error
      }
      _ => Err(TransportError::Failed)
    }
    let result = match outcome {
      Err(TransportError::Cancelled) => Err(GitHubError::Cancelled)
      // Transport error text is untrusted and can contain request tokens.
      Err(_) =>
        Err(
          GitHubError::Transport(
            message="request did not complete; remote outcome may be unknown",
          ),
        )
      Ok(response) if response.status >= 200 && response.status < 300 =>
        Ok(response)
      Ok(response) => Err(http_error(response))
    }
    let (status, request_id) = match outcome {
      Ok(response) =>
        (Some(response.status), response.header("x-github-request-id"))
      _ => (None, None)
    }
    let error_code = match result {
      Err(error) => Some(error.code())
      _ => None
    }
    self.record_attempt(
      request,
      operation_id~,
      operation_name~,
      attempt~,
      started~,
      status?,
      request_id?,
      error_code?,
      query_fingerprint?,
    )
    if attempt < max_attempts &&
      (request.verb == "GET" || request.verb == "HEAD") {
      match outcome {
        Ok(response) if retryable_status(response.status) => {
          attempt += 1
          continue
        }
        Err(TransportError::Failed | TransportError::Message(..)) => {
          attempt += 1
          continue
        }
        _ => ()
      }
    }
    return result
  }
}

///|
async fn Client::record_attempt(
  self : Client,
  request : Request,
  operation_id~ : String,
  operation_name~ : String,
  attempt~ : Int32,
  started~ : Int64,
  status? : Int32,
  request_id? : String,
  error_code? : String,
  query_fingerprint? : String,
) -> Unit {
  guard self.trace_observer is Some(observer) else { return }
  let secrets : Array[String] = []
  if self.config.token is Some(token) {
    secrets.push(token)
  }
  for (name, value) in request.headers {
    if name.equal_ignore_ascii_case("authorization") ||
      name.equal_ignore_ascii_case("cookie") ||
      name.to_lower().contains("token") ||
      name.to_lower().contains("api-key") {
      secrets.push(value)
      if value.split_once(" ") is Some((_, secret)) {
        secrets.push(secret.to_owned())
      }
    }
  }
  let host = parse_endpoint(request.url, query=true).map_or("redacted", endpoint => {
    endpoint.authority
  })
  let record = TraceRecord::new(
    host~,
    operation_name~,
    operation_id~,
    attempt~,
    verb=request.verb,
    path=request.path,
    status?,
    duration_ms=(self.clock)() - started,
    request_id?,
    error_code?,
    query_fingerprint?,
  ).redacted(secrets~)
  let succeeded = @async.protect_from_cancel(() => {
    @async.with_timeout(1000, () => {
      observer(record)
      true
    }) catch {
      _ => false
    }
  })
  if !succeeded {
    self.observer_failures += 1
  }
}

///|
fn Client::prepare(
  self : Client,
  request : Request,
  graphql~ : Bool,
) -> Result[Request, GitHubError] {
  guard valid_method(request.verb) else {
    return Err(InvalidRequest(message="invalid HTTP method"))
  }
  guard valid_path(request.path) else {
    return Err(InvalidRequest(message="invalid GitHub request path"))
  }
  guard request.query.length() <= 100 &&
    request.query.all(pair => {
      valid_query_part(pair.0) && valid_query_part(pair.1)
    }) else {
    return Err(InvalidRequest(message="invalid GitHub request query"))
  }
  guard valid_headers(request.headers) else {
    return Err(InvalidRequest(message="invalid or reserved GitHub header"))
  }
  let headers = request.headers.copy()
  if !has_header(headers, "Accept") {
    headers.push(("Accept", "application/vnd.github+json"))
  }
  if !has_header(headers, "X-GitHub-Api-Version") {
    headers.push(("X-GitHub-Api-Version", self.config.api_version))
  }
  if !has_header(headers, "User-Agent") {
    headers.push(("User-Agent", self.config.user_agent))
  }
  if request.body is Some(_) && !has_header(headers, "Content-Type") {
    headers.push(("Content-Type", "application/json"))
  }
  match self.config.token {
    Some(token) if !has_header(headers, "Authorization") => {
      guard valid_token(token) else {
        return Err(InvalidConfiguration(message="invalid GitHub token"))
      }
      headers.push(("Authorization", "Bearer " + token))
    }
    _ => ()
  }
  let base = if graphql {
    match self.config.graphql_url {
      Some(url) => url
      None => default_graphql_url(self.config.base_url)
    }
  } else if request.origin is Some(origin) {
    guard alternate_origin_allowed(self.config.base_url, origin) else {
      return Err(
        InvalidConfiguration(message="invalid GitHub alternate origin"),
      )
    }
    let normalized = match normalized_endpoint(origin) {
      Some(value) => value
      None =>
        return Err(
          InvalidConfiguration(message="invalid GitHub alternate origin"),
        )
    }
    join_url(normalized, request.path)
  } else {
    join_url(self.config.base_url, request.path)
  }
  let url = append_query(base, request.query)
  Ok({ ..request, url, headers, })
}

///|
/// GitHub serves release asset uploads from `uploads.github.com` while the
/// REST API uses `api.github.com`. Enterprise installations keep both
/// endpoints on the configured host. Requests may select this alternate
/// origin only through the trusted relationship below; arbitrary hosts never
/// become reachable through the SDK request seam.
fn alternate_origin_allowed(base_url : String, alternate : String) -> Bool {
  let base = match parse_endpoint(base_url) {
    Some(value) => value
    None => return false
  }
  let target = match parse_endpoint(alternate) {
    Some(value) => value
    None => return false
  }
  guard target.path == "/" else { return false }
  let base_scheme = base.origin
    .split_once("://")
    .map_or("", pair => pair.0.to_owned())
  let target_scheme = target.origin
    .split_once("://")
    .map_or("", pair => pair.0.to_owned())
  guard base_scheme == target_scheme else { return false }
  let base_host = base.authority
    .split_once(":")
    .map_or(base.authority, pair => pair.0.to_owned())
  let target_host = target.authority
    .split_once(":")
    .map_or(target.authority, pair => pair.0.to_owned())
  let expected_host = if base_host == "api.github.com" ||
    base_host.has_prefix("api.") {
    "uploads." + base_host[4:].to_owned()
  } else {
    base_host
  }
  let base_port = base.authority
    .split_once(":")
    .map_or("", pair => pair.1.to_owned())
  let target_port = target.authority
    .split_once(":")
    .map_or("", pair => pair.1.to_owned())
  target_host == expected_host && base_port == target_port
}

///|
pub struct GraphQLRequest {
  query : String
  operation_name : String?
  variables : Json?
  verb : String
  path : String
  headers : Array[(String, String)]
}

///|
pub fn GraphQLRequest::new(
  query~ : String,
  operation_name? : String,
  variables? : Json,
  verb~ : String = "POST",
  path~ : String = "/graphql",
  headers~ : Array[(String, String)] = [],
) -> GraphQLRequest {
  { query, operation_name, variables, verb, path, headers: headers.copy(), }
}

///|
pub fn GraphQLRequest::query(self : GraphQLRequest) -> String {
  self.query
}

///|
pub fn GraphQLRequest::operation_name(self : GraphQLRequest) -> String? {
  self.operation_name
}

///|
fn GraphQLRequest::to_json(self : GraphQLRequest) -> Json {
  let fields : Map[String, Json] = { "query": Json::string(self.query) }
  match self.operation_name {
    Some(value) => fields["operationName"] = Json::string(value)
    None => ()
  }
  match self.variables {
    Some(value) => fields["variables"] = value
    None => ()
  }
  Json::object(fields)
}

///|
pub struct GraphQLEnvelope {
  response : RawResponse
  data : Json?
  errors : Array[Json]
}

///|
pub fn GraphQLEnvelope::response(self : GraphQLEnvelope) -> RawResponse {
  self.response
}

///|
pub fn GraphQLEnvelope::data(self : GraphQLEnvelope) -> Json? {
  self.data
}

///|
pub fn GraphQLEnvelope::errors(self : GraphQLEnvelope) -> Array[Json] {
  self.errors.copy()
}

///|
fn request_copy(request : Request) -> Request {
  { ..request, query: request.query.copy(), headers: request.headers.copy(), }
}

///|
fn http_error(response : RawResponse) -> GitHubError {
  match response.status {
    401 => Authentication(response~)
    403 if is_rate_limit_response(response) => RateLimited(response~)
    403 => Permission(response~)
    429 => RateLimited(response~)
    409 => Conflict(response~)
    422 => Validation(response~)
    status if status >= 500 => Server(status~, response~)
    status => Http(status~, response~)
  }
}

///|
/// GitHub uses 403 for secondary limits as well as the primary limit. The
/// former may omit rate-limit headers, so inspect only the documented JSON
/// message (never arbitrary response text) as a fallback classifier.
fn is_rate_limit_response(response : RawResponse) -> Bool {
  if response.rate_limit().remaining == Some(0L) ||
    response.header("retry-after") is Some(_) {
    return true
  }
  let text = response.body_text().unwrap_or("").to_lower()
  let value : Json = @json.parse(text) catch { _ => Json::null() }
  match value {
    Object(fields) =>
      match fields.get("message") {
        Some(String(message)) => {
          let message = message.to_lower()
          message.contains("rate limit") || message.contains("rate-limit")
        }
        _ => false
      }
    _ => false
  }
}

///|
fn retryable_status(status : Int32) -> Bool {
  status == 429 || status >= 500
}

///|
fn join_url(base : String, path : String) -> String {
  if path == "/" {
    base
  } else {
    base + path
  }
}

///|
fn append_query(url : String, query : Array[(String, String)]) -> String {
  if query.is_empty() {
    url
  } else {
    let separator = if url.contains_char('?') { "&" } else { "?" }
    url +
    separator +
    query
    .map(pair => percent_encode(pair.0) + "=" + percent_encode(pair.1))
    .join("&")
  }
}

///|
fn default_graphql_url(base : String) -> String {
  match base.strip_suffix("/api/v3") {
    Some(origin) => origin.to_owned() + "/api/graphql"
    None => join_url(base, "/graphql")
  }
}

///|
fn percent_encode(value : String) -> String {
  let output = StringBuilder()
  for byte in @utf8.encode(value) {
    if is_unreserved(byte) {
      output.write_char(byte.to_int().to_char().unwrap())
    } else {
      let hex = "0123456789ABCDEF"
      output.write_char('%')
      output.write_char(hex.get_char(byte.to_int() / 16).unwrap())
      output.write_char(hex.get_char(byte.to_int() % 16).unwrap())
    }
  }
  output.to_string()
}

///|
fn is_unreserved(byte : Byte) -> Bool {
  byte is (b'a'..<=b'z') ||
  byte is (b'A'..<=b'Z') ||
  byte is (b'0'..<=b'9') ||
  byte == b'-' ||
  byte == b'.' ||
  byte == b'_' ||
  byte == b'~'
}

///|
fn valid_method(verb : String) -> Bool {
  !verb.is_empty() && verb.length() <= 32 && verb.iter().all(is_token_char)
}

///|
fn valid_path(path : String) -> Bool {
  guard path.has_prefix("/") &&
    !path.has_prefix("//") &&
    !path.contains_char('#') &&
    !path.contains_char('\\') &&
    path.iter().all(ch => ch.to_int() > 32 && ch.to_int() < 127) else {
    return false
  }
  let route = path.split("?").next().unwrap_or("").to_owned().to_lower()
  let decoded = route.replace_all(old="%2e", new=".")
  if decoded.split("/").any(part => part == "." || part == "..") {
    return false
  }
  let mut cursor = 0
  while cursor < path.length() {
    if path[cursor] == '%' {
      guard cursor + 2 < path.length() &&
        path[cursor + 1] is ('a'..<='f' | 'A'..<='F' | '0'..<='9') &&
        path[cursor + 2] is ('a'..<='f' | 'A'..<='F' | '0'..<='9') else {
        return false
      }
      cursor += 3
    } else {
      cursor += 1
    }
  }
  true
}

///|
fn valid_query_part(value : String) -> Bool {
  value.length() <= 1048576 &&
  value.iter().all(ch => ch.to_int() > 31 && ch.to_int() != 127)
}

///|
fn valid_headers(headers : Array[(String, String)]) -> Bool {
  for (name, value) in headers {
    let key = name.to_lower()
    guard !name.is_empty() &&
      name.iter().all(is_token_char) &&
      value.iter().all(ch => ch.to_int() >= 32 && ch.to_int() < 127) else {
      return false
    }
    match key {
      "host" | "content-length" | "transfer-encoding" | "connection" =>
        return false
      _ => ()
    }
  }
  true
}

///|
fn has_header(headers : Array[(String, String)], name : String) -> Bool {
  headers.any(pair => pair.0.equal_ignore_ascii_case(name))
}

///|
fn is_token_char(ch : Char) -> Bool {
  ch
  is ('a'..<='z'
  | 'A'..<='Z'
  | '0'..<='9'
  | '!'
  | '#'
  | '$'
  | '%'
  | '&'
  | '\''
  | '*'
  | '+'
  | '-'
  | '.'
  | '^'
  | '_'
  | '`'
  | '|'
  | '~')
}

///|
fn valid_token(value : String) -> Bool {
  value.length() > 0 &&
  value.length() <= 4096 &&
  value.iter().all(ch => ch.to_int() > 32 && ch.to_int() < 127)
}
