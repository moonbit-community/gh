///|
fn[T : @json.FromJson] decode_read(
  result : ReadResult[Json],
  valid? : (T) -> Bool = _ => true,
) -> ReadResult[T] {
  let value = match result.value {
    Err(error) => Err(error)
    Ok(json) =>
      try {
        let decoded : T = @json.from_json(json)
        if valid(decoded) {
          Ok(decoded)
        } else {
          Err(
            result.resource_failure(
              "MoonHub response does not match the requested resource",
            ),
          )
        }
      } catch {
        _ => Err(result.resource_failure("invalid MoonHub resource response"))
      }
  }
  {
    value,
    trace_failed: result.trace_failed,
    pages: result.pages,
    next: if value is Ok(_) {
      result.next
    } else {
      None
    },
    etag: if value is Ok(_) {
      result.etag
    } else {
      None
    },
    response_context: result.response_context,
  }
}

///|
fn[T] ReadResult::resource_failure(
  self : ReadResult[T],
  message : String,
) -> @gh.ApiFailure {
  match self.response_context {
    Some((status, request_id)) =>
      @gh.ApiFailure::new(kind=@gh.Decode(message~), status~, request_id?)
    None => @gh.ApiFailure::new(kind=@gh.Decode(message~))
  }
}

///|
fn[T] invalid_read(error : @gh.ApiError) -> ReadResult[T] {
  failed_read(@gh.ApiFailure::new(kind=error), false, 0)
}

///|
fn list_path(
  path : String,
  page : Int,
  per_page : Int,
) -> Result[String, @gh.ApiError] {
  if page < 1 || page > 1000000 || per_page < 1 || per_page > 100 {
    Err(
      @gh.InvalidRequest(
        message="page must be 1..1000000 and per_page must be 1..100",
      ),
    )
  } else {
    Ok("\{path}?page=\{page}&per_page=\{per_page}")
  }
}

///|
/// Fetch API capabilities without implicitly gating other operations on them.
pub async fn Client::meta(
  self : Client,
  operation_id~ : String,
) -> ReadResult[Meta] {
  decode_read(self.read_json(path="/meta", operation_id~))
}

///|
pub async fn Client::current_user(
  self : Client,
  operation_id~ : String,
) -> ReadResult[User] {
  decode_read(self.read_json(path="/user", operation_id~))
}

///|
pub async fn Client::repository(
  self : Client,
  repo : RepositoryRef,
  operation_id~ : String,
) -> ReadResult[Repository] {
  let path = match repo.api_path() {
    Ok(path) => path
    Err(error) => return invalid_read(error)
  }
  decode_read(self.read_json(path~, operation_id~), valid=repository => {
    repository.owner == repo.owner && repository.name == repo.name
  })
}

///|
/// List repositories visible to the current identity. The server owns access
/// filtering; the client never supplements these results with local storage.
pub async fn Client::repositories(
  self : Client,
  page? : Int = 1,
  per_page? : Int = 30,
  paginate? : Bool = false,
  max_pages? : Int = 20,
  operation_id~ : String,
) -> ReadResult[Array[Repository]] {
  let path = match list_path("/repos", page, per_page) {
    Ok(path) => path
    Err(error) => return invalid_read(error)
  }
  self.read_list(path~, operation_id~, paginate~, max_pages~)
}

///|
pub async fn Client::issues(
  self : Client,
  repo : RepositoryRef,
  page? : Int = 1,
  per_page? : Int = 30,
  paginate? : Bool = false,
  max_pages? : Int = 20,
  operation_id~ : String,
) -> ReadResult[Array[Issue]] {
  let base = match repo.api_path() {
    Ok(path) => path
    Err(error) => return invalid_read(error)
  }
  let path = match list_path(base + "/issues", page, per_page) {
    Ok(path) => path
    Err(error) => return invalid_read(error)
  }
  self.read_list(path~, operation_id~, paginate~, max_pages~)
}

///|
pub async fn Client::issue(
  self : Client,
  repo : RepositoryRef,
  number : Int,
  operation_id~ : String,
) -> ReadResult[Issue] {
  if number <= 0 {
    return invalid_read(
      @gh.InvalidRequest(message="issue number must be positive"),
    )
  }
  let base = match repo.api_path() {
    Ok(path) => path
    Err(error) => return invalid_read(error)
  }
  decode_read(self.read_json(path="\{base}/issues/\{number}", operation_id~), valid=issue => {
    issue.number == number
  })
}

///|
pub async fn Client::merge_requests(
  self : Client,
  repo : RepositoryRef,
  page? : Int = 1,
  per_page? : Int = 30,
  paginate? : Bool = false,
  max_pages? : Int = 20,
  operation_id~ : String,
) -> ReadResult[Array[MergeRequest]] {
  let base = match repo.api_path() {
    Ok(path) => path
    Err(error) => return invalid_read(error)
  }
  let path = match list_path(base + "/merge-requests", page, per_page) {
    Ok(path) => path
    Err(error) => return invalid_read(error)
  }
  self.read_list(path~, operation_id~, paginate~, max_pages~)
}

///|
pub async fn Client::merge_request(
  self : Client,
  repo : RepositoryRef,
  number : Int,
  operation_id~ : String,
) -> ReadResult[MergeRequest] {
  if number <= 0 {
    return invalid_read(
      @gh.InvalidRequest(message="merge request number must be positive"),
    )
  }
  let base = match repo.api_path() {
    Ok(path) => path
    Err(error) => return invalid_read(error)
  }
  decode_read(
    self.read_json(path="\{base}/merge-requests/\{number}", operation_id~),
    valid=mr => mr.number == number,
  )
}
