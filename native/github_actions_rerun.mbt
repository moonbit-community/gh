///|
fn actions_rest_failure(
  error : @github.GitHubError,
  prefix : String,
) -> @github_cli.Output {
  if error.response() is Some(response) && response.request_url() is Some(url) {
    return actions_failure(
      prefix +
      @github_cli.rest_error_message(
        response.status(),
        response.headers(),
        response.body(),
        url,
        reason_phrase?=response.reason_phrase(),
      ),
    )
  }
  actions_api_failure(error, prefix)
}

///|
async fn execute_actions_rerun(
  options : @github_cli.BusinessOptions,
  client : @github.Client,
  repository : @github_cli.RepositoryContext?,
  stderr_writer? : async (Bytes) -> Unit,
  format_context? : @github_cli.FormatContext,
) -> @github_cli.Output {
  let parsed = match @github_cli.parse_run_rerun(options) {
    Ok(value) => value
    Err(error) => return error
  }
  guard repository is Some(repo) else {
    return actions_failure("a repository is required")
  }
  let repository = repo.owner() + "/" + repo.name()
  let context = format_context.unwrap_or_else(() => process_format_context())
  let progress = StringBuilder()
  async fn write(bytes : Bytes) -> Unit {
    match stderr_writer {
      Some(writer) => writer(bytes)
      None => progress.write_string(@utf8.decode(bytes))
    }
  }
  fn finish(value : @github_cli.Output) -> @github_cli.Output {
    @github_cli.Output::new(
      stdout=value.stdout(),
      stderr=progress.to_string() + value.stderr(),
      exit_code=value.exit_code(),
    )
  }
  let mut run_id = parsed.run_id
  let mut job_id = ""
  let result = if parsed.job_id.is_empty() {
    let run = match
      with_terminal_progress(context, write, () => {
        @operations.get_workflow_run(client, repository, parsed.run_id)
      }) {
      Ok(run) => run
      Err(error) =>
        return finish(actions_rest_failure(error, "failed to get run: "))
    }
    run_id = run.id
    @operations.rerun_workflow_run(
      client,
      repository,
      run.id,
      only_failed=parsed.only_failed,
      debug_logging=parsed.debug_logging,
    )
  } else {
    let job = match
      with_terminal_progress(context, write, () => {
        @operations.get_workflow_job(client, repository, parsed.job_id)
      }) {
      Ok(job) => job
      Err(error) =>
        return finish(actions_rest_failure(error, "failed to get job: "))
    }
    run_id = job.run_id
    job_id = job.id
    @operations.rerun_workflow_job(
      client,
      repository,
      job.id,
      debug_logging=parsed.debug_logging,
    )
  }
  let output = match result {
    Ok(_) =>
      @github_cli.success(
        stdout=@github_cli.render_rerun_requested(
          run_id,
          job_id,
          parsed.only_failed,
          parsed.debug_logging,
          context,
        ),
      )
    Err(error) => {
      if error.response() is Some(response) && response.status() == 403 {
        if !parsed.job_id.is_empty() {
          return finish(
            actions_failure("job " + parsed.job_id + " cannot be rerun"),
          )
        }
        let value = @json.parse(response.body_text().unwrap_or("")) catch {
          _ => Json::null()
        }
        let message = match value {
          { "message": String(message), .. } => message
          _ => "request failed"
        }
        return finish(
          actions_failure(
            "run " + parsed.run_id + " cannot be rerun; " + message,
          ),
        )
      }
      actions_rest_failure(error, "failed to rerun: ")
    }
  }
  finish(output)
}
