///|
/// Methods accepted by the transport. Constructors are usable by SDK callers.
pub(all) enum HttpMethod {
  Get
  Post
  Put
  Patch
  Delete
}

///|
pub fn HttpMethod::as_string(self : HttpMethod) -> String {
  match self {
    Get => "GET"
    Post => "POST"
    Put => "PUT"
    Patch => "PATCH"
    Delete => "DELETE"
  }
}

///|
pub fn all_http_methods() -> Array[HttpMethod] {
  [Get, Post, Put, Patch, Delete]
}

///|
pub fn get_method() -> HttpMethod {
  Get
}

///|
/// An origin-relative HTTP request. Headers and body may contain secrets;
/// deliberately no Debug/Show/ToJson implementation is provided.
pub struct Request {
  verb : HttpMethod
  path : String
  body : String?
  headers : Array[(String, String)]
}

///|
pub fn Request::new(
  verb~ : HttpMethod,
  path~ : String,
  body? : String,
  headers? : Array[(String, String)] = [],
) -> Request {
  { verb, path, body, headers: headers.copy(), }
}

///|
/// Buffered HTTP response. Injected adapters may preserve duplicate headers;
/// the native upstream HTTP implementation coalesces them.
/// Raw response bodies must not be placed into diagnostics or traces.
pub struct Response {
  status : Int
  body : String
  headers : Array[(String, String)]
}

///|
pub fn Response::new(
  status~ : Int,
  body~ : String,
  headers? : Array[(String, String)] = [],
) -> Response {
  { status, body, headers: headers.copy(), }
}

///|
/// Returns the first matching header using case-insensitive field names.
pub fn Response::header(self : Response, name : String) -> String? {
  for (key, value) in self.headers {
    if key.equal_ignore_ascii_case(name) {
      return Some(value)
    }
  }
  None
}

///|
pub(all) enum ApiError {
  InvalidRequest(message~ : String)
  Transport(message~ : String)
  Unauthorized
  Forbidden
  NotFound
  Conflict(message~ : String)
  RateLimited
  Server(status~ : Int, message~ : String)
  UnexpectedStatus(status~ : Int)
  Decode(message~ : String)
}

///|
/// Stable categories for diagnostics and trace; never includes payload text.
pub fn ApiError::code(self : ApiError) -> String {
  match self {
    InvalidRequest(..) => "invalid_request"
    Transport(..) => "transport"
    Unauthorized => "unauthorized"
    Forbidden => "forbidden"
    NotFound => "not_found"
    Conflict(..) => "conflict"
    RateLimited => "rate_limited"
    Server(..) => "server"
    UnexpectedStatus(..) => "unexpected_status"
    Decode(..) => "decode"
  }
}

///|
/// Only call for non-2xx responses. Message must already be safe to display.
pub fn api_error_for_status(status~ : Int, message~ : String) -> ApiError {
  match status {
    400 | 422 => InvalidRequest(message~)
    401 => Unauthorized
    403 => Forbidden
    404 => NotFound
    409 | 412 => Conflict(message~)
    429 => RateLimited
    500..=599 => Server(status~, message~)
    _ => UnexpectedStatus(status~)
  }
}

///|
pub fn transport_error(message~ : String) -> ApiError {
  Transport(message~)
}

///|
/// Safe SDK error details. HTTP status remains authoritative even when the
/// server error envelope is malformed. code is a recognized server error code.
pub struct ApiFailure {
  kind : ApiError
  status : Int?
  code : String?
  request_id : String?
}

///|
pub fn ApiFailure::new(
  kind~ : ApiError,
  status? : Int,
  code? : String,
  request_id? : String,
) -> ApiFailure {
  { kind, status, code, request_id, }
}

///|
/// Inject an asynchronous HTTP operation. A native adapter or an in-memory
/// test callback implements the same boundary; there is no global transport.
pub struct Transport {
  origin : String
  priv send_request : async (Request) -> Response
}

///|
pub fn Transport::new(
  origin~ : String,
  send~ : async (Request) -> Response,
) -> Transport {
  { origin, send_request: send, }
}

///|
pub async fn Transport::send(self : Transport, request : Request) -> Response {
  (self.send_request)(request)
}
