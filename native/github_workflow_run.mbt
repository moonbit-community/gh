///|
async fn workflow_inputs(
  options : @github_cli.WorkflowRunOptions,
) -> Result[Json, @github_cli.Output] {
  if options.json_input {
    let bytes = match read_api_input("-") {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    let value = @json.parse(@utf8.decode(bytes)) catch {
      _ =>
        return Err(
          actions_failure("could not parse provided JSON: invalid JSON input"),
        )
    }
    return @github_cli.workflow_json_inputs(value)
  }
  let values : Map[String, Json] = Map([])
  // gh processes raw fields before magic fields, regardless of argv order.
  for
    (fields, read_files) in [
      (options.raw_fields, false),
      (options.file_fields, true),
    ] {
    for field in fields {
      let (key, value) = match @github_cli.workflow_input_pair(field) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let value = if read_files && value.strip_prefix("@") is Some(path) {
        let bytes = match read_api_input(path.to_owned()) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        @utf8.decode(bytes) catch {
          _ =>
            return Err(
              actions_failure(
                "error parsing " +
                Json(key).stringify() +
                " value: invalid UTF-8",
              ),
            )
        }
      } else {
        value
      }
      values[key] = Json(value)
    }
  }
  Ok(Json::object(values))
}

///|
async fn execute_workflow_run(
  options : @github_cli.BusinessOptions,
  client : @github.Client,
  repository : @github_cli.RepositoryContext?,
) -> @github_cli.Output {
  let parsed = match @github_cli.parse_workflow_run(options) {
    Ok(value) => value
    Err(error) => return error
  }
  guard repository is Some(repo) else {
    return actions_failure("a repository is required")
  }
  let repository = repo.owner() + "/" + repo.name()
  let branch = if parsed.ref_name.is_empty() {
    match @operations.workflow_default_branch(client, repository) {
      Ok(value) => value
      Err(error) =>
        return actions_api_failure(
          error,
          "unable to determine default branch for " + repository + ": ",
        )
    }
  } else {
    parsed.ref_name
  }
  let workflow = match
    @operations.resolve_workflow(client, repository, parsed.selector) {
    Ok(value) => value
    Err(error) => return actions_api_failure(error, "")
  }
  let inputs = match workflow_inputs(parsed) {
    Ok(value) => value
    Err(error) => return error
  }
  let result = match
    @operations.dispatch_workflow(
      client,
      repository,
      workflow.id,
      branch,
      inputs,
    ) {
    Ok(value) => value
    Err(error) =>
      return actions_api_failure(
        error, "could not create workflow dispatch event: ",
      )
  }
  @github_cli.success(
    stdout=if result.html_url.is_empty() { "" } else { result.html_url + "\n" },
  )
}
