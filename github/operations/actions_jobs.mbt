///|
pub struct WorkflowStep {
  name : String
  number : Int32
  status : String
  conclusion : String
}

///|
pub struct WorkflowJob {
  id : String
  run_id : String
  name : String
  status : String
  conclusion : String
  started_at : String
  completed_at : String
  steps : Array[WorkflowStep]
}

///|
pub struct WorkflowRun {
  id : String
  status : String
  conclusion : String
  started_at : String
  workflow_name : String
  head_branch : String
  head_repository : String
  event : String
  jobs_url : String
}

///|
fn field(value : Json, key : String) -> Json {
  match value {
    Object(fields) => fields.get(key).unwrap_or(Json::null())
    _ => Json::null()
  }
}

///|
fn text(value : Json, key : String) -> String {
  match field(value, key) {
    String(value) => value
    _ => ""
  }
}

///|
fn id(value : Json, key : String) -> String? {
  match field(value, key) {
    Number(number, ..) if number > 0 &&
      number < 9007199254740992.0 &&
      number == number.to_int64().to_double() =>
      Some(number.to_int64().to_string())
    _ => None
  }
}

///|
async fn request_json(
  client : @github.Client,
  path : String,
  operation_id~ : String = "actions-logs",
  operation_name~ : String = "actions.logs.metadata",
) -> Result[(Json, @github.RawResponse), @github.GitHubError] {
  let response = match
    client.request(
      @github.Request::new(verb="GET", path~),
      operation_id~,
      operation_name~,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let value = @json.parse(@utf8.decode(response.body())) catch {
    _ => return Err(@github.GitHubError::decode("invalid Actions JSON"))
  }
  Ok((value, response))
}

///|
fn run_path(repository : String, run_id : String, attempt : String?) -> String? {
  guard valid_repository(repository) && numeric_id(run_id) else { return None }
  let path = "/repos/" + repository + "/actions/runs/" + run_id
  match attempt {
    None | Some("0") => Some(path)
    Some(attempt) if numeric_id(attempt) => Some(path + "/attempts/" + attempt)
    _ => None
  }
}

///|
pub async fn get_workflow_run(
  client : @github.Client,
  repository : String,
  run_id : String,
  attempt? : String,
) -> Result[WorkflowRun, @github.GitHubError] {
  guard run_path(repository, run_id, attempt) is Some(path) else {
    return Err(
      @github.GitHubError::invalid_request("invalid workflow run or attempt"),
    )
  }
  let (value, _) = match
    request_json(client, path + "?exclude_pull_requests=true") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  guard id(value, "id") is Some(actual_id) &&
    actual_id == run_id &&
    id(value, "workflow_id") is Some(workflow_id) else {
    return Err(@github.GitHubError::decode("workflow run identity mismatch"))
  }
  // gh resolves the parent workflow when loading a run, including log views.
  let workflow = match
    request_json(
      client,
      "/repos/" + repository + "/actions/workflows/" + workflow_id,
    ) {
    Err(error) => return Err(error)
    Ok((workflow, _)) => workflow
  }
  let started = text(value, "run_started_at")
  Ok({
    id: actual_id,
    status: text(value, "status"),
    conclusion: text(value, "conclusion"),
    started_at: if started.is_empty() || started == "0001-01-01T00:00:00Z" {
      text(value, "created_at")
    } else {
      started
    },
    workflow_name: text(workflow, "name"),
    head_branch: text(value, "head_branch"),
    head_repository: text(
      field(field(value, "head_repository"), "owner"),
      "login",
    ) +
    "/" +
    text(field(value, "head_repository"), "name"),
    event: text(value, "event"),
    jobs_url: text(value, "jobs_url"),
  })
}

///|
fn decode_job(value : Json) -> Result[WorkflowJob, @github.GitHubError] {
  guard id(value, "id") is Some(job_id) && id(value, "run_id") is Some(run_id) else {
    return Err(@github.GitHubError::decode("missing workflow job identity"))
  }
  let steps : Array[WorkflowStep] = []
  if field(value, "steps") is Array(values) {
    for step in values {
      guard field(step, "number") is Number(number, ..) &&
        number >= 0 &&
        number <= 2147483647.0 &&
        number == number.to_int().to_double() else {
        return Err(@github.GitHubError::decode("invalid workflow step number"))
      }
      steps.push({
        name: text(step, "name"),
        number: number.to_int(),
        status: text(step, "status"),
        conclusion: text(step, "conclusion"),
      })
    }
  }
  Ok({
    id: job_id,
    run_id,
    name: text(value, "name"),
    status: text(value, "status"),
    conclusion: text(value, "conclusion"),
    started_at: text(value, "started_at"),
    completed_at: text(value, "completed_at"),
    steps,
  })
}

///|
pub async fn get_workflow_job(
  client : @github.Client,
  repository : String,
  job_id : String,
) -> Result[WorkflowJob, @github.GitHubError] {
  guard valid_repository(repository) && numeric_id(job_id) else {
    return Err(@github.GitHubError::invalid_request("invalid workflow job"))
  }
  let (value, _) = match
    request_json(client, "/repos/" + repository + "/actions/jobs/" + job_id) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match decode_job(value) {
    Ok(job) if job.id == job_id => Ok(job)
    Ok(_) => Err(@github.GitHubError::decode("workflow job identity mismatch"))
    Err(error) => Err(error)
  }
}

///|
pub async fn list_workflow_jobs(
  client : @github.Client,
  repository : String,
  run_id : String,
  attempt? : String,
  max_pages~ : Int32 = 1000,
) -> Result[Array[WorkflowJob], @github.GitHubError] {
  guard run_path(repository, run_id, attempt) is Some(run) && max_pages > 0 else {
    return Err(@github.GitHubError::invalid_request("invalid jobs request"))
  }
  let base = client.config.base_url()
  let collection = run + "/jobs"
  let mut path = collection + "?per_page=100"
  let seen : Map[String, Unit] = Map([])
  let identities : Map[String, Unit] = Map([])
  let jobs : Array[WorkflowJob] = []
  for _ in 0..<max_pages {
    guard !seen.contains(path) else {
      return Err(@github.GitHubError::decode("repeated jobs page"))
    }
    seen[path] = ()
    let (value, response) = match request_json(client, path) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    guard field(value, "jobs") is Array(items) else {
      return Err(@github.GitHubError::decode("missing jobs collection"))
    }
    for item in items {
      let job = match decode_job(item) {
        Ok(job) => job
        Err(error) => return Err(error)
      }
      guard job.run_id == run_id && !identities.contains(job.id) else {
        return Err(
          @github.GitHubError::decode("mismatched or repeated workflow job"),
        )
      }
      identities[job.id] = ()
      jobs.push(job)
    }
    match response.next_url(current_url=base + path) {
      Err(error) => return Err(error)
      Ok(None) => return Ok(jobs)
      Ok(Some(url)) => {
        guard url.strip_prefix(base + collection + "?") is Some(query) &&
          !query.is_empty() else {
          return Err(
            @github.GitHubError::decode("jobs pagination left its collection"),
          )
        }
        path = collection + "?" + query.to_owned()
      }
    }
  }
  Err(@github.GitHubError::decode("jobs pagination limit reached"))
}
