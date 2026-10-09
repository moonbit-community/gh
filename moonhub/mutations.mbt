///|
fn[T] invalid_mutation(error : @gh.ApiError) -> MutationResult[T] {
  {
    value: Err(@gh.ApiFailure::new(kind=error)),
    trace_failed: false,
    etag: None,
    outcome: NotSent,
  }
}

///|
fn mutation_failure_outcome(error : @gh.ApiFailure) -> MutationOutcome {
  match error.status {
    Some(status) if status >= 400 && status < 500 => Rejected
    None if error.kind is @gh.InvalidRequest(..) => NotSent
    _ => Unknown
  }
}

///|
/// Execute one mutation without preflight reads or retries. A success status
/// alone cannot establish success when its receipt violates the contract.
async fn[T : @json.FromJson] Client::write_json(
  self : Client,
  path~ : String,
  body~ : Json,
  expected_status~ : Int,
  require_etag~ : Bool,
  valid~ : (T) -> Bool,
  if_match? : EntityTag,
  operation_id~ : String,
) -> MutationResult[T] {
  let headers = match if_match {
    Some(tag) => [("If-Match", tag.value())]
    None => []
  }
  let call = self.execute(
    @gh.Request::new(verb=@gh.Post, path~, body=body.stringify(), headers~),
    operation_id~,
  )
  let response = match call.response {
    Ok(response) => response
    Err(error) =>
      return {
        value: Err(error),
        trace_failed: call.trace_failed,
        etag: None,
        outcome: mutation_failure_outcome(error),
      }
  }
  let failure = fn(message : String) -> MutationResult[T] {
    {
      value: Err(self.read_failure(response, message)),
      trace_failed: call.trace_failed,
      etag: None,
      outcome: Unknown,
    }
  }
  if response.status != expected_status {
    let metadata = self.read_failure(response, "unexpected mutation status")
    let request_id = metadata.request_id
    return {
      value: Err(
        @gh.ApiFailure::new(
          kind=@gh.UnexpectedStatus(status=response.status),
          status=response.status,
          request_id?,
        ),
      ),
      trace_failed: call.trace_failed,
      etag: None,
      outcome: Unknown,
    }
  }
  let etag = match response_etag(response) {
    Ok(etag) => etag
    Err(_) => return failure("invalid or repeated response ETag")
  }
  if require_etag && etag is None {
    return failure("mutation response is missing its ETag")
  }
  let envelope = @wire_json.parse(response.body) catch {
    _ => return failure("invalid MoonHub mutation response envelope")
  }
  guard envelope is { "version": version, "data": data, .. } &&
    @wire_json.integer(version, minimum=1, maximum=1) is Some(_) else {
    return failure("invalid MoonHub mutation response envelope")
  }
  let value : T = @json.from_json(data) catch {
    _ => return failure("invalid MoonHub mutation response")
  }
  if !valid(value) {
    return failure(
      "mutation response does not match the requested resource or state",
    )
  }
  {
    value: Ok(value),
    trace_failed: call.trace_failed,
    etag,
    outcome: if expected_status == 202 {
      Accepted
    } else {
      Applied
    },
  }
}

///|
fn mutation_resource_path(
  repo : RepositoryRef,
  collection : String,
  number : Int,
) -> Result[String, @gh.ApiError] {
  if number <= 0 {
    return Err(@gh.InvalidRequest(message="resource number must be positive"))
  }
  match repo.api_path() {
    Ok(base) => Ok("\{base}/\{collection}/\{number}")
    Err(error) => Err(error)
  }
}

///|
fn valid_title_description(title : String, description : String) -> Bool {
  !title.is_empty() && title.length() <= 200 && description.length() <= 20000
}

///|
fn valid_comment(body : String) -> Bool {
  !body.trim().is_empty() && body.length() <= 20000
}

///|
fn valid_branch_input(value : String) -> Bool {
  !value.trim().is_empty() &&
  value.length() <= 1024 &&
  value
  .iter()
  .all(character => character.to_int() >= 32 && character.to_int() != 127)
}

///|
pub async fn Client::create_issue(
  self : Client,
  repo : RepositoryRef,
  title~ : String,
  description? : String = "",
  operation_id~ : String,
) -> MutationResult[Issue] {
  let title = title.trim().to_owned()
  if !valid_title_description(title, description) {
    return invalid_mutation(
      @gh.InvalidRequest(
        message="title must be 1..200 characters and description at most 20000",
      ),
    )
  }
  let base = match repo.api_path() {
    Ok(base) => base
    Err(error) => return invalid_mutation(error)
  }
  self.write_json(
    path=base + "/issues",
    body={ "title": title.to_json(), "description": description.to_json() },
    expected_status=201,
    require_etag=true,
    valid=issue => issue.status == "open",
    operation_id~,
  )
}

///|
pub async fn Client::comment_issue(
  self : Client,
  repo : RepositoryRef,
  number : Int,
  body~ : String,
  operation_id~ : String,
) -> MutationResult[CommentReceipt] {
  if !valid_comment(body) {
    return invalid_mutation(
      @gh.InvalidRequest(
        message="comment must be nonblank and at most 20000 characters",
      ),
    )
  }
  let path = match mutation_resource_path(repo, "issues", number) {
    Ok(path) => path + "/comments"
    Err(error) => return invalid_mutation(error)
  }
  self.write_json(
    path~,
    body={ "body": body.to_json() },
    expected_status=201,
    require_etag=false,
    valid=receipt => receipt.number == number,
    operation_id~,
  )
}

///|
pub async fn Client::close_issue(
  self : Client,
  repo : RepositoryRef,
  number : Int,
  if_match~ : EntityTag,
  operation_id~ : String,
) -> MutationResult[Issue] {
  let path = match mutation_resource_path(repo, "issues", number) {
    Ok(path) => path + "/close"
    Err(error) => return invalid_mutation(error)
  }
  self.write_json(
    path~,
    body=Json::object({}),
    if_match~,
    expected_status=200,
    require_etag=true,
    valid=issue => issue.number == number && issue.status == "closed",
    operation_id~,
  )
}

///|
pub async fn Client::reopen_issue(
  self : Client,
  repo : RepositoryRef,
  number : Int,
  if_match~ : EntityTag,
  operation_id~ : String,
) -> MutationResult[Issue] {
  let path = match mutation_resource_path(repo, "issues", number) {
    Ok(path) => path + "/reopen"
    Err(error) => return invalid_mutation(error)
  }
  self.write_json(
    path~,
    body=Json::object({}),
    if_match~,
    expected_status=200,
    require_etag=true,
    valid=issue => issue.number == number && issue.status == "open",
    operation_id~,
  )
}

///|
pub async fn Client::create_merge_request(
  self : Client,
  repo : RepositoryRef,
  title~ : String,
  source~ : String,
  target~ : String,
  description? : String = "",
  draft? : Bool = false,
  operation_id~ : String,
) -> MutationResult[MergeRequest] {
  let title = title.trim().to_owned()
  if !valid_title_description(title, description) {
    return invalid_mutation(
      @gh.InvalidRequest(
        message="title must be 1..200 characters and description at most 20000",
      ),
    )
  }
  if !valid_branch_input(source) ||
    !valid_branch_input(target) ||
    source == target {
    return invalid_mutation(
      @gh.InvalidRequest(
        message="source and target must be distinct nonempty branch names",
      ),
    )
  }
  let base = match repo.api_path() {
    Ok(base) => base
    Err(error) => return invalid_mutation(error)
  }
  self.write_json(
    path=base + "/merge-requests",
    body={
      "title": title.to_json(),
      "description": description.to_json(),
      "source": source.to_json(),
      "target": target.to_json(),
      "draft": draft.to_json(),
    },
    expected_status=201,
    require_etag=true,
    valid=mr => {
      mr.status == "open" &&
      mr.source == source &&
      mr.target == target &&
      mr.draft == draft
    },
    operation_id~,
  )
}

///|
pub async fn Client::comment_merge_request(
  self : Client,
  repo : RepositoryRef,
  number : Int,
  body~ : String,
  if_match~ : EntityTag,
  operation_id~ : String,
) -> MutationResult[CommentReceipt] {
  if !valid_comment(body) {
    return invalid_mutation(
      @gh.InvalidRequest(
        message="comment must be nonblank and at most 20000 characters",
      ),
    )
  }
  let path = match mutation_resource_path(repo, "merge-requests", number) {
    Ok(path) => path + "/comments"
    Err(error) => return invalid_mutation(error)
  }
  self.write_json(
    path~,
    body={ "body": body.to_json() },
    if_match~,
    expected_status=201,
    require_etag=false,
    valid=receipt => receipt.number == number,
    operation_id~,
  )
}

///|
pub async fn Client::merge_merge_request(
  self : Client,
  repo : RepositoryRef,
  number : Int,
  if_match~ : EntityTag,
  operation_id~ : String,
) -> MutationResult[MergeReceipt] {
  let path = match mutation_resource_path(repo, "merge-requests", number) {
    Ok(path) => path + "/merge"
    Err(error) => return invalid_mutation(error)
  }
  self.write_json(
    path~,
    body=Json::object({}),
    if_match~,
    expected_status=202,
    require_etag=false,
    valid=receipt => receipt.number == number,
    operation_id~,
  )
}
