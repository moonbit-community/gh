///|
async fn execute_cache_delete(
  options : @github_cli.BusinessOptions,
  client : @github.Client,
  repository : @github_cli.RepositoryContext?,
  stderr_writer? : async (Bytes) -> Unit,
  format_context? : @github_cli.FormatContext,
) -> @github_cli.Output {
  let parsed = match @github_cli.parse_cache_delete(options) {
    Ok(value) => value
    Err(error) => return error
  }
  guard repository is Some(repo) else {
    return actions_failure("a repository is required")
  }
  let name = repo.owner() + "/" + repo.name()
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
  let failure_icon = @github_cli.actions_failure_icon(context)
  let identifiers = if parsed.all {
    match
      with_terminal_progress(context, write, () => {
        @operations.workflow_cache_ids(client, name, ref_name=parsed.ref_name)
      }) {
      Ok(ids) => ids
      Err(error) => return finish(actions_rest_failure(error, ""))
    }
  } else {
    [parsed.identifier]
  }
  if identifiers.is_empty() {
    return finish(
      if parsed.succeed_on_empty {
        @github_cli.success(
          stdout=if context.terminal {
            @github_cli.actions_success_icon(context) + " No caches to delete\n"
          } else {
            ""
          },
        )
      } else {
        actions_failure(failure_icon + " No caches to delete")
      },
    )
  }
  let result = with_terminal_progress(context, write, () => {
    let mut total = 0
    for identifier in identifiers {
      let cache_id = @github_cli.cache_identifier_id(identifier)
      match
        @operations.delete_workflow_cache(
          client,
          name,
          cache_id.unwrap_or(identifier),
          by_id=cache_id is Some(_),
          ref_name=if parsed.all { "" } else { parsed.ref_name },
        ) {
        Ok(count) => total += count
        Err(error) => {
          if error.status() == Some(404) {
            return actions_failure(
              failure_icon +
              " Could not find a cache matching " +
              identifier +
              (if parsed.ref_name.is_empty() {
                ""
              } else {
                " (with ref " + parsed.ref_name + ")"
              }) +
              " in " +
              name,
            )
          }
          return actions_rest_failure(
            error,
            failure_icon + " Failed to delete cache: ",
          )
        }
      }
    }
    @github_cli.success(
      stdout=@github_cli.render_cache_deleted(total, name, context),
    )
  })
  finish(result)
}
