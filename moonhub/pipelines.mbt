///|
/// Public run summary. A run number is repository-local and preserves the
/// server's signed Int64 range without relying on JSON number precision.
pub struct Pipeline {
  number : String
  workflow_path : String
  workflow_name : String
  source_branch : String
  commit_sha : String
  state : String
  conclusion : String?
  created_at : String
}

///|
/// Durable acceptance of a cancellation request, not proof that a runner has
/// stopped. Read the pipeline again to observe its eventual conclusion.
pub struct PipelineCancelReceipt {
  number : String
  kind : String
}

///|
pub extend Pipeline with @json.FromJson::{from_json}

///|
pub extend PipelineCancelReceipt with @json.FromJson::{from_json}

///|
fn valid_pipeline_number(value : String) -> Bool {
  decimal_string(value, allow_zero=false) &&
  value.length() <= 19 &&
  (value.length() < 19 || value <= "9223372036854775807")
}

///|
/// Validate a canonical repository-local run number before command dispatch.
/// No whitespace, leading zero, sign, fractional spelling or overflow is accepted.
pub fn parse_pipeline_number(value : String) -> Result[String, @gh.ApiError] {
  if valid_pipeline_number(value) {
    Ok(value)
  } else {
    Err(
      @gh.InvalidRequest(
        message="pipeline number must be a canonical positive signed Int64 decimal",
      ),
    )
  }
}

///|
fn pipeline_number_field(
  fields : Map[String, Json],
  path : @json.JsonPath,
) -> String raise @json.JsonDecodeError {
  let number : String = required_field(fields, "number", path)
  guard valid_pipeline_number(number) else {
    resource_invalid(path.add_key("number"))
  }
  number
}

///|
pub impl @json.FromJson for Pipeline with fn from_json(value, path) {
  let fields = resource_object(value, path)
  let number = pipeline_number_field(fields, path)
  let state : String = required_field(fields, "state", path)
  guard state is ("queued" | "running" | "completed") else {
    resource_invalid(path.add_key("state"))
  }
  // This relation is enforced by MoonHub's database: only completed runs have
  // conclusions. Missing optional fields remain compatible with null.
  let conclusion = optional_string(fields, "conclusion", path)
  guard (match (state, conclusion) {
    (
      "completed",
      Some("success" | "failure" | "cancelled" | "timed_out" | "lost"),
    ) => true
    ("queued" | "running", None) => true
    _ => false
  }) else {
    resource_invalid(path.add_key("conclusion"))
  }
  let commit_sha : String = required_field(fields, "commit_sha", path)
  guard (commit_sha.length() == 40 || commit_sha.length() == 64) &&
    commit_sha.iter().all(character => character is ('0'..='9' | 'a'..='f')) else {
    resource_invalid(path.add_key("commit_sha"))
  }
  {
    number,
    workflow_path: required_field(fields, "workflow_path", path),
    workflow_name: required_field(fields, "workflow_name", path),
    source_branch: required_field(fields, "source_branch", path),
    commit_sha,
    state,
    conclusion,
    created_at: required_field(fields, "created_at", path),
  }
}

///|
pub impl @json.FromJson for PipelineCancelReceipt with fn from_json(value, path) {
  let fields = resource_object(value, path)
  let kind : String = required_field(fields, "kind", path)
  guard kind == "cancel_requested" else {
    resource_invalid(path.add_key("kind"))
  }
  { number: pipeline_number_field(fields, path), kind, }
}

///|
pub fn Pipeline::to_json(self : Pipeline) -> Json {
  {
    "number": self.number.to_json(),
    "workflow_path": self.workflow_path.to_json(),
    "workflow_name": self.workflow_name.to_json(),
    "source_branch": self.source_branch.to_json(),
    "commit_sha": self.commit_sha.to_json(),
    "state": self.state.to_json(),
    "conclusion": nullable_string(self.conclusion),
    "created_at": self.created_at.to_json(),
  }
}

///|
pub fn PipelineCancelReceipt::to_json(self : PipelineCancelReceipt) -> Json {
  { "number": self.number.to_json(), "kind": self.kind.to_json() }
}

///|
fn pipeline_path(
  repo : RepositoryRef,
  number : String,
) -> Result[String, @gh.ApiError] {
  match parse_pipeline_number(number) {
    Err(error) => Err(error)
    Ok(number) =>
      match repo.api_path() {
        Ok(base) => Ok("\{base}/pipelines/\{number}")
        Err(error) => Err(error)
      }
  }
}

///|
pub async fn Client::pipelines(
  self : Client,
  repo : RepositoryRef,
  page? : Int = 1,
  per_page? : Int = 30,
  paginate? : Bool = false,
  max_pages? : Int = 20,
  operation_id~ : String,
) -> ReadResult[Array[Pipeline]] {
  let base = match repo.api_path() {
    Ok(path) => path
    Err(error) => return invalid_read(error)
  }
  let path = match list_path(base + "/pipelines", page, per_page) {
    Ok(path) => path
    Err(error) => return invalid_read(error)
  }
  self.read_list(path~, operation_id~, paginate~, max_pages~)
}

///|
pub async fn Client::pipeline(
  self : Client,
  repo : RepositoryRef,
  number : String,
  operation_id~ : String,
) -> ReadResult[Pipeline] {
  let path = match pipeline_path(repo, number) {
    Ok(path) => path
    Err(error) => return invalid_read(error)
  }
  decode_read(self.read_json(path~, operation_id~), valid=run => {
    run.number == number
  })
}

///|
/// Send one conditional cancellation. 202 means the durable request was
/// accepted; active runners may still be stopping after this returns.
pub async fn Client::cancel_pipeline(
  self : Client,
  repo : RepositoryRef,
  number : String,
  if_match~ : EntityTag,
  operation_id~ : String,
) -> MutationResult[PipelineCancelReceipt] {
  let path = match pipeline_path(repo, number) {
    Ok(path) => path + "/cancel"
    Err(error) => return invalid_mutation(error)
  }
  self.write_json(
    path~,
    body=Json::empty_object(),
    if_match~,
    expected_status=202,
    require_etag=false,
    valid=receipt => receipt.number == number,
    operation_id~,
  )
}

///|
/// Create a new queued run from the completed run's immutable snapshot.
/// Applied refers to snapshot creation, not successful workflow execution.
pub async fn Client::rerun_pipeline(
  self : Client,
  repo : RepositoryRef,
  number : String,
  if_match~ : EntityTag,
  operation_id~ : String,
) -> MutationResult[Pipeline] {
  let path = match pipeline_path(repo, number) {
    Ok(path) => path + "/rerun"
    Err(error) => return invalid_mutation(error)
  }
  self.write_json(
    path~,
    body=Json::empty_object(),
    if_match~,
    expected_status=201,
    require_etag=true,
    valid=run => run.number != number && run.state == "queued",
    operation_id~,
  )
}
