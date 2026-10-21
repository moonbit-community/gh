///|
async fn request_rerun(
  client : @github.Client,
  repository : String,
  identifier : String,
  job~ : Bool,
  only_failed~ : Bool = false,
  debug_logging~ : Bool = false,
) -> Result[Unit, @github.GitHubError] {
  guard valid_repository(repository) && numeric_id(identifier) else {
    return Err(
      @github.GitHubError::invalid_request("invalid Actions rerun target"),
    )
  }
  let path = "/repos/" +
    repository +
    "/actions/" +
    (if job { "jobs/" } else { "runs/" }) +
    identifier +
    (if only_failed && !job { "/rerun-failed-jobs" } else { "/rerun" })
  let body = if debug_logging {
    Some(b"{\"enable_debug_logging\":true}\n")
  } else {
    None
  }
  match
    client.request(
      @github.Request::new(verb="POST", path~, body?),
      operation_id="actions-rerun",
      operation_name="run.rerun",
    ) {
    Ok(_) => Ok(())
    Err(error) => Err(error)
  }
}

///|
pub async fn rerun_workflow_run(
  client : @github.Client,
  repository : String,
  run_id : String,
  only_failed~ : Bool = false,
  debug_logging~ : Bool = false,
) -> Result[Unit, @github.GitHubError] {
  request_rerun(
    client,
    repository,
    run_id,
    job=false,
    only_failed~,
    debug_logging~,
  )
}

///|
pub async fn rerun_workflow_job(
  client : @github.Client,
  repository : String,
  job_id : String,
  debug_logging~ : Bool = false,
) -> Result[Unit, @github.GitHubError] {
  request_rerun(client, repository, job_id, job=true, debug_logging~)
}
