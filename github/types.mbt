///|
/// A byte-preserving HTTP request passed to an injected transport.
///
/// `path` is origin-relative and `url` includes the configured API origin and
/// encoded query string. Headers intentionally remain an ordered array so
/// adapters can preserve repeated fields.
pub struct Request {
  verb : String
  url : String
  path : String
  query : Array[(String, String)]
  headers : Array[(String, String)]
  body : Bytes?
  // An optional trusted alternate origin (currently used by GitHub's release
  // asset upload host).  The client validates it against its configured API
  // origin before constructing the URL.
  origin : String?
}

///|
pub fn Request::verb(self : Request) -> String {
  self.verb
}

///|
pub fn Request::url(self : Request) -> String {
  self.url
}

///|
pub fn Request::path(self : Request) -> String {
  self.path
}

///|
pub fn Request::query(self : Request) -> Array[(String, String)] {
  self.query.copy()
}

///|
pub fn Request::headers(self : Request) -> Array[(String, String)] {
  self.headers.copy()
}

///|
pub fn Request::body(self : Request) -> Bytes? {
  self.body
}

///|
pub fn Request::new(
  verb~ : String,
  path~ : String,
  query~ : Array[(String, String)] = [],
  headers~ : Array[(String, String)] = [],
  body? : Bytes,
  origin? : String,
) -> Request {
  {
    verb,
    url: path,
    path,
    query: query.copy(),
    headers: headers.copy(),
    body,
    origin,
  }
}

///|
pub fn Request::with_text_body(
  verb~ : String,
  path~ : String,
  text~ : String,
  query~ : Array[(String, String)] = [],
  headers~ : Array[(String, String)] = [],
) -> Request {
  Request::new(verb~, path~, query~, headers~, body=@utf8.encode(text))
}

///|
/// A raw response. No JSON decoding or text conversion occurs at this layer.
pub struct RawResponse {
  status : Int32
  reason_phrase : String?
  headers : Array[(String, String)]
  body : Bytes
  // Filled by Client, not trusted from the transport. Never included in trace
  // records or a derived debug representation.
  priv request_url : String?
}

///|
pub fn RawResponse::new(
  status~ : Int32,
  headers~ : Array[(String, String)] = [],
  body~ : Bytes = b"",
  reason_phrase? : String,
) -> RawResponse {
  { status, reason_phrase, headers: headers.copy(), body, request_url: None, }
}

///|
/// The request that produced this response, when sent through Client.
/// This can contain query values; callers must not log it as diagnostic data.
pub fn RawResponse::request_url(self : RawResponse) -> String? {
  self.request_url
}

///|
pub fn RawResponse::reason_phrase(self : RawResponse) -> String? {
  self.reason_phrase
}

///|
pub fn RawResponse::status(self : RawResponse) -> Int32 {
  self.status
}

///|
pub fn RawResponse::headers(self : RawResponse) -> Array[(String, String)] {
  self.headers.copy()
}

///|
pub fn RawResponse::body(self : RawResponse) -> Bytes {
  self.body
}

///|
pub fn RawResponse::body_text(self : RawResponse) -> Result[String, Unit] {
  Ok(@utf8.decode(self.body)) catch {
    _ => Err(())
  }
}

///|
pub fn RawResponse::header(self : RawResponse, name : String) -> String? {
  for (key, value) in self.headers {
    if key.equal_ignore_ascii_case(name) {
      return Some(value)
    }
  }
  None
}

///|
/// A transport failure is deliberately separate from an HTTP failure. The
/// transport adapter should pass a safe, static message here.
pub(all) enum TransportError {
  Failed
  Message(message~ : String)
  Cancelled
}

///|
pub fn TransportError::message(self : TransportError) -> String {
  match self {
    Failed => "transport request failed"
    Message(message~) => message
    Cancelled => "request cancelled"
  }
}

///|
/// An injected asynchronous HTTP boundary. It performs no retries or
/// redirects by itself.
pub struct Transport {
  priv send_request : async (Request) -> Result[RawResponse, TransportError]
  priv receive_request : (async (Request, @gh.RawResponseSink) -> Result[
    @gh.RawDownloadResult,
    TransportError,
  ])?
}

///|
pub fn Transport::new(
  send~ : async (Request) -> Result[RawResponse, TransportError],
  receive? : async (Request, @gh.RawResponseSink) -> Result[
    @gh.RawDownloadResult,
    TransportError,
  ],
) -> Transport {
  { send_request: send, receive_request: receive, }
}

///|
async fn Transport::receive(
  self : Transport,
  request : Request,
  sink : @gh.RawResponseSink,
) -> Result[@gh.RawDownloadResult, TransportError] {
  if self.receive_request is Some(receive) {
    return receive(request, sink)
  }
  let response = match self.send(request) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let head = @gh.RawResponseHead::new(
    status=response.status(),
    headers=response.headers(),
    reason_phrase?=response.reason_phrase(),
  )
  if !sink.headers(head) {
    return Ok(
      @gh.RawDownloadResult::new(head~, bytes_received=0L, complete=false),
    )
  }
  if !response.body().is_empty() {
    sink.chunk(response.body())
  }
  Ok(
    @gh.RawDownloadResult::new(
      head~,
      bytes_received=response.body().length().to_int64(),
      complete=true,
    ),
  )
}

///|
async fn Transport::send(
  self : Transport,
  request : Request,
) -> Result[RawResponse, TransportError] {
  (self.send_request)(request)
}

///|
/// Retry behavior is explicit. `Disabled` is the default and always makes a
/// single transport attempt.
pub enum RetryPolicy {
  Disabled
  Attempts(Int32)
  ServerErrors(Int32, Int32)
}

///|
pub fn RetryPolicy::default() -> RetryPolicy {
  Disabled
}

///|
pub fn RetryPolicy::limited(max_attempts~ : Int32) -> RetryPolicy {
  if max_attempts < 1 {
    Attempts(1)
  } else {
    Attempts(max_attempts)
  }
}

///|
fn RetryPolicy::max_attempts(self : RetryPolicy) -> Int32 {
  match self {
    Disabled => 1
    Attempts(value) => value
    ServerErrors(value, _) => value
  }
}

///|
/// Retry only HTTP 500–599 on read requests. Transport failures, rate limits,
/// and writes are not retried. The delay is cancellable and each attempt
/// produces its own trace record.
pub fn RetryPolicy::server_errors(
  max_attempts~ : Int32,
  delay_ms~ : Int32 = 200,
) -> RetryPolicy {
  ServerErrors(max_attempts.max(1), delay_ms.max(0))
}

///|
fn RetryPolicy::should_retry(
  self : RetryPolicy,
  outcome : Result[RawResponse, TransportError],
) -> Bool {
  match (self, outcome) {
    (Disabled, _) => false
    (ServerErrors(_, _), Ok(response)) =>
      response.status >= 500 && response.status <= 599
    (ServerErrors(_, _), _) => false
    (Attempts(_), Ok(response)) => retryable_status(response.status)
    (Attempts(_), Err(TransportError::Failed | TransportError::Message(..))) =>
      true
    _ => false
  }
}

///|
fn RetryPolicy::delay_ms(self : RetryPolicy) -> Int32 {
  match self {
    ServerErrors(_, delay) => delay
    _ => 0
  }
}

///|
/// Errors returned by the GitHub client. HTTP and GraphQL errors retain the
/// raw response so callers can decide how to render an API error body.
pub enum GitHubError {
  InvalidConfiguration(message~ : String)
  InvalidRequest(message~ : String)
  Transport(message~ : String)
  Authentication(response~ : RawResponse)
  Permission(response~ : RawResponse)
  RateLimited(response~ : RawResponse)
  Conflict(response~ : RawResponse)
  Validation(response~ : RawResponse)
  Server(status~ : Int32, response~ : RawResponse)
  Http(status~ : Int32, response~ : RawResponse)
  Decode(message~ : String)
  GraphQL(response~ : RawResponse, errors~ : Array[Json])
  Cancelled
}

///|
pub fn GitHubError::invalid_request(message : String) -> GitHubError {
  InvalidRequest(message~)
}

///|
pub fn GitHubError::decode(message : String) -> GitHubError {
  Decode(message~)
}

///|
/// Preserve partial GraphQL errors at typed-operation boundaries.
pub fn GitHubError::graphql(
  response : RawResponse,
  errors : Array[Json],
) -> GitHubError {
  GraphQL(response~, errors~)
}

///|
pub fn GitHubError::status(self : GitHubError) -> Int32? {
  match self {
    Authentication(response~) => Some(response.status)
    Permission(response~) => Some(response.status)
    RateLimited(response~) => Some(response.status)
    Conflict(response~) => Some(response.status)
    Validation(response~) => Some(response.status)
    Server(status~, ..) => Some(status)
    Http(status~, ..) => Some(status)
    GraphQL(response~, ..) => Some(response.status)
    _ => None
  }
}

///|
pub fn GitHubError::response(self : GitHubError) -> RawResponse? {
  match self {
    Authentication(response~) => Some(response)
    Permission(response~) => Some(response)
    RateLimited(response~) => Some(response)
    Conflict(response~) => Some(response)
    Validation(response~) => Some(response)
    Server(status=_, response~) => Some(response)
    Http(response~, ..) => Some(response)
    GraphQL(response~, ..) => Some(response)
    _ => None
  }
}

///|
pub fn GitHubError::code(self : GitHubError) -> String {
  match self {
    InvalidConfiguration(..) => "invalid_configuration"
    InvalidRequest(..) => "invalid_request"
    Transport(..) => "transport"
    Authentication(..) => "authentication"
    Permission(..) => "permission"
    RateLimited(..) => "rate_limited"
    Conflict(..) => "conflict"
    Validation(..) => "validation"
    Server(..) => "server"
    Http(..) => "http"
    Decode(..) => "decode"
    GraphQL(..) => "graphql"
    Cancelled => "cancelled"
  }
}

///|
/// Client settings. `token` is never included in any public formatter or
/// request URL; the client turns it into an Authorization header.
pub struct ClientConfig {
  base_url : String
  graphql_url : String?
  api_version : String
  user_agent : String
  priv token : String?
  priv trace_observer : (async (TraceRecord) -> Unit)?
}

///|
pub fn ClientConfig::new(
  base_url~ : String,
  graphql_url? : String,
  api_version~ : String = "2022-11-28",
  user_agent~ : String = "gh-moonbit/0.1.0",
  token? : String,
  trace_observer? : async (TraceRecord) -> Unit,
) -> ClientConfig {
  { base_url, graphql_url, api_version, user_agent, token, trace_observer, }
}

///|
pub fn ClientConfig::base_url(self : ClientConfig) -> String {
  self.base_url
}

///|
pub fn ClientConfig::graphql_url(self : ClientConfig) -> String? {
  self.graphql_url
}

///|
pub fn ClientConfig::api_version(self : ClientConfig) -> String {
  self.api_version
}

///|
pub fn ClientConfig::user_agent(self : ClientConfig) -> String {
  self.user_agent
}

///|
pub fn ClientConfig::has_token(self : ClientConfig) -> Bool {
  self.token is Some(_)
}
