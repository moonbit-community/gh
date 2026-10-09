///|
/// Bounded retries for typed GET operations. Raw execute and all mutations
/// always send one attempt. max_attempts includes the first attempt per page.
pub struct ReadRetryPolicy {
  max_attempts : Int
  initial_delay_ms : Int
  max_delay_ms : Int
}

///|
pub fn ReadRetryPolicy::default() -> ReadRetryPolicy {
  { max_attempts: 3, initial_delay_ms: 100, max_delay_ms: 2000, }
}

///|
/// One attempt disables retries. Delay bounds apply both to local backoff and
/// the accepted Retry-After minimum; an excessive server minimum stops retries.
pub fn ReadRetryPolicy::new(
  max_attempts? : Int = 3,
  initial_delay_ms? : Int = 100,
  max_delay_ms? : Int = 2000,
) -> Result[ReadRetryPolicy, @gh.ApiError] {
  if max_attempts < 1 ||
    max_attempts > 5 ||
    initial_delay_ms < 0 ||
    max_delay_ms < initial_delay_ms ||
    max_delay_ms > 30000 {
    Err(@gh.InvalidRequest(message="invalid read retry bounds"))
  } else {
    Ok({ max_attempts, initial_delay_ms, max_delay_ms, })
  }
}

///|
priv enum RetryAfter {
  Absent
  Delay(Int)
  Stop
}

///|
/// Dates need a trustworthy wall clock and are deliberately not guessed.
/// Invalid, duplicate, coalesced or excessive hints stop retries conservatively.
fn retry_after(response : @gh.Response, maximum : Int) -> RetryAfter {
  let mut found = false
  let mut seconds = 0
  for (name, value) in response.headers {
    if name.equal_ignore_ascii_case("retry-after") {
      if found || value.is_empty() || value.length() > 10 {
        return Stop
      }
      found = true
      for ch in value.iter() {
        guard ch is ('0'..='9') else { return Stop }
        seconds = seconds * 10 + ch.to_int() - 48
        if seconds > maximum / 1000 {
          return Stop
        }
      }
    }
  }
  if found {
    Delay(seconds * 1000)
  } else {
    Absent
  }
}

///|
fn retryable_failure(failure : @gh.ApiFailure) -> Bool {
  match failure.kind {
    @gh.Transport(..) => true
    _ => failure.status is Some(429 | 502 | 503 | 504)
  }
}

///|
/// Policy operates on sanitized API results, preserving each response's trace
/// and Retry-After hint. Upstream async.retry retries exceptions, so using it
/// here would require artificial errors and out-of-band response state.
async fn Client::read_attempts(
  self : Client,
  path~ : String,
  operation_id~ : String,
  first_attempt~ : Int,
) -> (CallResult, Int) {
  for used = 1, delay = self.read_retry.initial_delay_ms, prior_trace_failed = false {
    let (call, hint) = self.execute_attempt(
      @gh.Request::new(verb=@gh.Get, path~),
      operation_id~,
      attempt=first_attempt + used - 1,
    )
    let call = {
      response: call.response,
      trace_failed: prior_trace_failed || call.trace_failed,
    }
    guard call.response is Err(failure) &&
      retryable_failure(failure) &&
      used < self.read_retry.max_attempts else {
      return (call, used)
    }
    let wait = match hint {
      Stop => return (call, used)
      Absent => delay
      Delay(server_delay) =>
        if server_delay > delay {
          server_delay
        } else {
          delay
        }
    }
    // Cancellation during backoff propagates; no fictitious network attempt
    // or trace is generated before the next transport call actually starts.
    (self.retry_wait)(wait)
    let doubled = delay * 2
    let next_delay = if doubled > self.read_retry.max_delay_ms {
      self.read_retry.max_delay_ms
    } else {
      doubled
    }
    continue used + 1, next_delay, call.trace_failed
  }
}
