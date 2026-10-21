///|
async fn execute_actions_download(
  options : @github_cli.BusinessOptions,
  client : @github.Client,
  repository : @github_cli.RepositoryContext?,
) -> @github_cli.Output {
  let parsed = match @github_cli.parse_run_download(options) {
    Ok(value) => value
    Err(error) => return error
  }
  guard repository is Some(repo) else {
    return @github_cli.failure(message="a repository is required")
  }
  let artifacts = match
    @operations.list_artifacts(
      client,
      repo.owner() + "/" + repo.name(),
      run_id?=parsed.run_id,
    ) {
    Ok(values) => values
    Err(error) =>
      return actions_api_failure(error, "error fetching artifacts: ")
  }
  guard artifacts.any(artifact => !artifact.expired()) else {
    return actions_failure("no valid artifacts found to download")
  }
  let names : Map[String, Unit] = Map([])
  let selected = artifacts.filter(artifact => {
    if artifact.expired() ||
      names.contains(artifact.name()) ||
      !parsed.matches(artifact.name()) {
      false
    } else {
      names[artifact.name()] = ()
      true
    }
  })
  guard !selected.is_empty() else {
    return actions_failure(
      "no artifact matches any of the names or patterns provided",
    )
  }
  guard valid_local_file_path(parsed.directory) else {
    return @github_cli.failure(message="invalid download directory")
  }
  // Validate every selected name before downloading or publishing any file.
  if parsed.isolated() &&
    selected.any(artifact => !business_asset_filename(artifact.name())) {
    return @github_cli.failure(
      message="artifact name would result in path traversal",
    )
  }
  let temporary = @fs.tmpdir(prefix="gh-actions-download-")
  defer @fs.rmdir(temporary, recursive=true)
  for artifact in selected {
    let source = temporary + "/artifact.zip"
    let mut remote_error : @github.GitHubError? = None
    try {
      let result = @download.to_file(
        source,
        sink => {
          match
            client.download_actions_archive_into(artifact.download_path(), sink) {
            Ok(value) => value
            Err(error) => {
              remote_error = Some(error)
              fail("artifact download failed")
            }
          }
        },
        replace=true,
      )
      guard result.complete() else { fail("artifact download incomplete") }
      let target = if parsed.isolated() {
        parsed.directory + "/" + artifact.name()
      } else {
        parsed.directory
      }
      ignore(@download.extract_zip(source, target))
    } catch {
      error if @async.is_being_cancelled() => raise error
      _ => {
        let detail = match remote_error {
          Some(error) => error.code()
          None => "archive download or extraction failed"
        }
        return @github_cli.failure(
          message="error downloading " + artifact.name() + ": " + detail,
          exit_code=if remote_error is Some(@github.Cancelled) { 2 } else { 1 },
        )
      }
    }
  }
  @github_cli.success(stdout="")
}
