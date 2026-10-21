///|
async fn execute_workflow_manage(
  options : @github_cli.BusinessOptions,
  client : @github.Client,
  repository : @github_cli.RepositoryContext?,
  stderr_writer? : async (Bytes) -> Unit,
  format_context? : @github_cli.FormatContext,
) -> @github_cli.Output {
  let parsed = match @github_cli.parse_workflow_manage(options) {
    Ok(value) => value
    Err(error) => return error
  }
  let repository = match business_repository_arg(options) {
    Some(value) =>
      match @github_cli.RepositoryContext::parse(value) {
        Ok(value) => Some(value)
        Err(_) =>
          return actions_failure("expected the [HOST/]OWNER/REPO format")
      }
    None => repository
  }
  guard repository is Some(repo) else {
    return actions_failure("a repository is required")
  }
  let repository = repo.owner() + "/" + repo.name()
  let context = format_context.unwrap_or_else(() => process_format_context())
  if parsed.action == "list" {
    let progress = StringBuilder()
    async fn write(bytes : Bytes) -> Unit {
      match stderr_writer {
        Some(writer) => writer(bytes)
        None => progress.write_string(@utf8.decode(bytes))
      }
    }
    let result = with_terminal_progress(context, write, () => {
      @operations.list_workflows(client, repository, limit=parsed.limit)
    })
    let output = match result {
      Ok(workflows) => @github_cli.render_workflows(workflows, parsed, context)
      Err(error) => actions_rest_failure(error, "could not get workflows: ")
    }
    return @github_cli.Output::new(
      stdout=output.stdout(),
      stderr=progress.to_string() + output.stderr(),
      exit_code=output.exit_code(),
    )
  }
  let enabled = parsed.action == "enable"
  let workflow = match
    @operations.resolve_workflow(
      client,
      repository,
      parsed.selector,
      states=if enabled {
        ["disabled_manually", "disabled_inactivity"]
      } else {
        ["active"]
      },
    ) {
    Ok(value) => value
    Err(error) => {
      if @operations.workflow_selector_is_direct(parsed.selector) &&
        error.status() == Some(404) &&
        error.response() is Some(response) {
        return actions_failure(
          "HTTP 404: workflow " +
          parsed.selector +
          " not found on the default branch" +
          response.request_url().map_or("", url => " (" + url + ")"),
        )
      }
      return actions_rest_failure(
        error,
        if !@operations.workflow_selector_is_direct(parsed.selector) &&
          error.response() is Some(_) {
          "couldn't fetch workflows for " + repository + ": "
        } else {
          ""
        },
      )
    }
  }
  match
    @operations.set_workflow_enabled(client, repository, workflow.id, enabled) {
    Err(error) =>
      actions_rest_failure(error, "failed to " + parsed.action + " workflow: ")
    Ok(_) =>
      @github_cli.success(
        stdout=@github_cli.render_workflow_state(
          workflow.name,
          enabled,
          context,
        ),
      )
  }
}
