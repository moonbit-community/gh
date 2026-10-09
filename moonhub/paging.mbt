///|
/// A logical read, which may span several HTTP attempts. Failed reads contain
/// no partial data. pages counts successfully decoded response envelopes;
/// next is an SDK-relative continuation path for single-page list reads.
pub struct ReadResult[T] {
  value : Result[T, @gh.ApiFailure]
  trace_failed : Bool
  pages : Int
  next : String?
  etag : EntityTag?
  // Single-resource decoding uses this context. Lists decode each page before
  // following its Link, so their failures already carry the correct response.
  priv response_context : (Int, String?)?
}

///|
fn Client::read_failure(
  self : Client,
  response : @gh.Response,
  message : String,
) -> @gh.ApiFailure {
  let request_id = self.response_request_id(response)
  @gh.ApiFailure::new(
    kind=@gh.Decode(message~),
    status=response.status,
    request_id?,
  )
}

///|
fn Client::response_request_id(
  self : Client,
  response : @gh.Response,
) -> String? {
  let request_id = match response.header("x-request-id") {
    Some(value) => safe_request_id(value)
    None => None
  }
  match request_id {
    Some(value) if self.secrets().any(secret => value.contains(secret)) => None
    other => other
  }
}

///|
/// Injected transports may preserve repeated Link fields. Combine them before
/// parsing so split next links and ambiguous next links have the same meaning
/// as the native transport's coalesced header map.
fn response_next_path(
  response : @gh.Response,
  origin~ : String,
  current_path~ : String,
) -> Result[String?, @gh.ApiError] {
  let combined = StringBuilder()
  let mut remaining = 65536
  let mut found = false
  for (name, value) in response.headers {
    if name.equal_ignore_ascii_case("link") {
      let separator = if found { 1 } else { 0 }
      guard remaining >= separator && value.length() <= remaining - separator else {
        return Err(@gh.Decode(message="invalid pagination link"))
      }
      remaining -= separator + value.length()
      if found {
        combined.write_char(',')
      }
      combined.write_string(value)
      found = true
    }
  }
  if found {
    @pagination.next_path(combined.to_string(), origin~, current_path~)
  } else {
    Ok(None)
  }
}

///|
fn[T] failed_read(
  error : @gh.ApiFailure,
  trace_failed : Bool,
  pages : Int,
) -> ReadResult[T] {
  {
    value: Err(error),
    trace_failed,
    pages,
    next: None,
    etag: None,
    response_context: None,
  }
}

///|
fn Client::response_data(
  self : Client,
  response : @gh.Response,
) -> Result[Json, @gh.ApiFailure] {
  let json = @wire_json.parse(response.body) catch { _ => Json::null() }
  if json is { "version": version, "data": data, .. } &&
    @wire_json.integer(version, minimum=1, maximum=1) is Some(_) {
    Ok(data)
  } else {
    Err(self.read_failure(response, "invalid MoonHub v1 response envelope"))
  }
}

///|
/// A single-resource read retains its response context for typed decoding.
async fn Client::read_json(
  self : Client,
  path~ : String,
  operation_id~ : String,
) -> ReadResult[Json] {
  let (call, _) = self.read_attempts(path~, operation_id~, first_attempt=1)
  let response = match call.response {
    Ok(response) => response
    Err(error) => return failed_read(error, call.trace_failed, 0)
  }
  let data = match self.response_data(response) {
    Ok(data) => data
    Err(error) => return failed_read(error, call.trace_failed, 0)
  }
  let etag = match response_etag(response) {
    Ok(etag) => etag
    Err(_) =>
      return failed_read(
        self.read_failure(response, "invalid or repeated response ETag"),
        call.trace_failed,
        0,
      )
  }
  {
    value: Ok(data),
    trace_failed: call.trace_failed,
    pages: 1,
    next: None,
    etag,
    response_context: Some(
      (response.status, self.response_request_id(response)),
    ),
  }
}

///|
/// Decode each bounded page once, before another request. A bad resource cannot
/// trigger more requests or lose its response ID in an aggregate JSON array.
async fn[T : @json.FromJson] Client::read_list(
  self : Client,
  path~ : String,
  operation_id~ : String,
  paginate? : Bool = false,
  max_pages? : Int = 20,
  max_items? : Int = 1000,
) -> ReadResult[Array[T]] {
  if max_pages < 1 || max_pages > 100 || max_items < 1 || max_items > 10000 {
    return invalid_read(@gh.InvalidRequest(message="invalid pagination bounds"))
  }
  let items : Array[T] = []
  for current = path, pages = 0, attempts = 0, prior_trace_failed = false {
    let (call, used) = self.read_attempts(
      path=current,
      operation_id~,
      first_attempt=attempts + 1,
    )
    let trace_failed = prior_trace_failed || call.trace_failed
    let response = match call.response {
      Ok(response) => response
      Err(error) => return failed_read(error, trace_failed, pages)
    }
    let data = match self.response_data(response) {
      Ok(data) => data
      Err(error) => return failed_read(error, trace_failed, pages)
    }
    guard data is Array(batch) else {
      return failed_read(
        self.read_failure(response, "expected a MoonHub resource list"),
        trace_failed,
        pages,
      )
    }
    let pages = pages + 1
    if batch.length() > max_items - items.length() {
      return failed_read(
        self.read_failure(response, "pagination item limit exceeded"),
        trace_failed,
        pages,
      )
    }
    let batch : Array[T] = @json.from_json(data) catch {
      _ =>
        return failed_read(
          self.read_failure(response, "invalid MoonHub resource response"),
          trace_failed,
          pages,
        )
    }
    for item in batch {
      items.push(item)
    }
    let next = match
      response_next_path(
        response,
        origin=self.config.base_url,
        current_path=current,
      ) {
      Ok(next) => next
      Err(_) =>
        return failed_read(
          self.read_failure(response, "invalid pagination link"),
          trace_failed,
          pages,
        )
    }
    if !paginate || next is None {
      return {
        value: Ok(items),
        trace_failed,
        pages,
        next,
        etag: None,
        response_context: None,
      }
    }
    guard next is Some(path) else { abort("unreachable pagination state") }
    // next_path already requires the same route and exactly page + 1, so a
    // separate visited-path set cannot detect any additional cycles.
    if pages >= max_pages {
      return failed_read(
        self.read_failure(response, "pagination page limit exceeded"),
        trace_failed,
        pages,
      )
    }
    continue path, pages, attempts + used, trace_failed
  }
}
