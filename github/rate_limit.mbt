///|
/// Server metadata only. Reading these fields never waits or retries. Invalid
/// or duplicate numeric headers remain absent rather than being guessed.
pub struct RateLimit {
  limit : Int64?
  remaining : Int64?
  used : Int64?
  reset_epoch_seconds : Int64?
  retry_after_seconds : Int64?
  retry_after : String?
  resource : String?
}

///|
pub fn RateLimit::limit(self : RateLimit) -> Int64? {
  self.limit
}

///|
pub fn RateLimit::remaining(self : RateLimit) -> Int64? {
  self.remaining
}

///|
pub fn RateLimit::used(self : RateLimit) -> Int64? {
  self.used
}

///|
pub fn RateLimit::reset_epoch_seconds(self : RateLimit) -> Int64? {
  self.reset_epoch_seconds
}

///|
pub fn RateLimit::retry_after_seconds(self : RateLimit) -> Int64? {
  self.retry_after_seconds
}

///|
pub fn RateLimit::resource(self : RateLimit) -> String? {
  self.resource
}

///|
pub fn RawResponse::rate_limit(self : RawResponse) -> RateLimit {
  {
    limit: rate_integer(self, "x-ratelimit-limit"),
    remaining: rate_integer(self, "x-ratelimit-remaining"),
    used: rate_integer(self, "x-ratelimit-used"),
    reset_epoch_seconds: rate_integer(self, "x-ratelimit-reset"),
    retry_after_seconds: rate_integer(self, "retry-after"),
    retry_after: unique_header(self, "retry-after"),
    resource: unique_header(self, "x-ratelimit-resource"),
  }
}

///|
fn unique_header(response : RawResponse, name : String) -> String? {
  let mut found : String? = None
  for (key, value) in response.headers {
    if key.equal_ignore_ascii_case(name) {
      if found is Some(_) {
        return None
      }
      found = Some(value)
    }
  }
  found
}

///|
fn rate_integer(response : RawResponse, name : String) -> Int64? {
  guard unique_header(response, name) is Some(value) &&
    !value.is_empty() &&
    value.length() <= 19 &&
    value.iter().all(ch => ch is ('0'..<='9')) else {
    return None
  }
  let parsed = @string.parse_int64(value) catch { _ => return None }
  if parsed >= 0 {
    Some(parsed)
  } else {
    None
  }
}
