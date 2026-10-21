///|
fn actions_failure(
  message : String,
  exit_code~ : Int32 = 1,
) -> @github_cli.Output {
  @github_cli.Output::new(stderr=message + "\n", exit_code~)
}

///|
fn actions_api_failure(
  error : @github.GitHubError,
  prefix : String,
) -> @github_cli.Output {
  let message = match error {
    @github.Decode(message~) | @github.InvalidRequest(message~) => message
    _ =>
      if error.response() is Some(response) {
        let body = @json.parse(response.body_text().unwrap_or("")) catch {
          _ => Json::null()
        }
        let message = match body {
          { "message": String(message), .. } => message
          _ => "request failed"
        }
        "HTTP \{response.status()}: " + message
      } else {
        error.code()
      }
  }
  actions_failure(
    prefix + message,
    exit_code=if error is @github.Cancelled { 2 } else { 1 },
  )
}

///|
async fn actions_file(
  client : @github.Client,
  path : String,
  target : String,
) -> Result[Unit, @github_cli.Output] {
  let mut remote_error : @github.GitHubError? = None
  try {
    let result = @download.to_file(
      target,
      sink => {
        match client.download_actions_archive_into(path, sink) {
          Ok(value) => value
          Err(error) => {
            remote_error = Some(error)
            fail("Actions download failed")
          }
        }
      },
      replace=true,
    )
    guard result.complete() else { fail("incomplete Actions download") }
    Ok(())
  } catch {
    error if @async.is_being_cancelled() => raise error
    _ =>
      match remote_error {
        Some(error) => Err(actions_api_failure(error, ""))
        None => Err(actions_failure("could not save Actions download"))
      }
  }
}

///|
async fn execute_actions_logs(
  parsed : ParsedBusiness,
  client : @github.Client,
  repository : @github_cli.RepositoryContext?,
  cache_directory : String?,
) -> @github_cli.Output {
  if parsed_flag(parsed, "log") && parsed_flag(parsed, "log_failed") {
    return actions_failure("specify only one of --log or --log-failed")
  }
  if parsed_flag(parsed, "web") && parsed_flag(parsed, "log") {
    return actions_failure("specify only one of --web or --log")
  }
  guard repository is Some(repo) else {
    return actions_failure("a repository is required")
  }
  guard parsed.positionals.length() <= 1 else {
    return actions_failure("accepts at most 1 arg(s), received 2")
  }
  let repository = repo.owner() + "/" + repo.name()
  let mut selected_job : @operations.WorkflowJob? = None
  let run_id = if parsed.values.get("job") is Some(job_id) {
    let job = match @operations.get_workflow_job(client, repository, job_id) {
      Ok(job) => job
      Err(error) => return actions_api_failure(error, "failed to get job: ")
    }
    selected_job = Some(job)
    job.run_id
  } else if parsed.positionals.get(0) is Some(run_id) {
    run_id
  } else {
    return actions_failure(
      "run or job ID required when not running interactively",
    )
  }
  let attempt = parsed.values.get("attempt")
  let run = match
    @operations.get_workflow_run(client, repository, run_id, attempt?) {
    Ok(value) => value
    Err(error) => return actions_api_failure(error, "failed to get run: ")
  }
  let jobs = match selected_job {
    Some(job) => [job]
    None =>
      match
        @operations.list_workflow_jobs(client, repository, run_id, attempt?) {
        Ok(jobs) => jobs
        Err(error) => return actions_api_failure(error, "failed to get jobs: ")
      }
  }
  if selected_job is Some(job) && job.status != "completed" {
    return actions_failure(
      "job \{job.id} is still in progress; logs will be available when it is complete",
    )
  }
  if run.status != "completed" {
    return actions_failure(
      "run \{run.id} is still in progress; logs will be available when it is complete",
    )
  }
  let temporary = @fs.tmpdir(prefix="gh-run-logs-")
  defer @fs.rmdir(temporary, recursive=true)
  let temporary_archive = temporary + "/logs.zip"
  let cache_path = match cache_directory {
    None => None
    Some(directory) => {
      let seconds = if run.started_at.is_empty() {
        -62135596800L
      } else {
        guard run.started_at.strip_suffix("Z") is Some(value) else {
          return actions_failure("invalid workflow start timestamp")
        }
        let time : @time.PlainDateTime = @string.from_str(value) catch {
          _ => return actions_failure("invalid workflow start timestamp")
        }
        time.to_unix_second()
      }
      Some(
        directory + "/run-log-" + run.id + "-" + seconds.to_string() + ".zip",
      )
    }
  }
  let cached = cache_path is Some(path) && @fs.exists(path)
  let archive_path = if cached {
    cache_path.unwrap()
  } else {
    temporary_archive
  }
  let prefix = "/repos/" + repository + "/actions"
  let log_path = prefix +
    "/runs/" +
    run_id +
    (match attempt {
      Some(value) if value != "0" => "/attempts/" + value
      _ => ""
    }) +
    "/logs"
  if !cached && actions_file(client, log_path, archive_path) is Err(error) {
    return @github_cli.Output::new(
      stderr="failed to get run log: " + error.stderr(),
      exit_code=error.exit_code(),
    )
  }
  let entries = try {
    guard @fs.kind(archive_path, follow_symlink=false) == @fs.Regular &&
      @fs.file_size(archive_path) <= 67108864L else {
      fail("invalid log ZIP file")
    }
    @archive.decode_zip(
      @fs.read_file(archive_path).binary(),
      cancelled=@async.is_being_cancelled,
    )
  } catch {
    error if @async.is_being_cancelled() => raise error
    _ =>
      return actions_failure(
        "failed to get run log: invalid or oversized ZIP archive",
      )
  }
  if !cached && cache_directory is Some(directory) && cache_path is Some(path) {
    try {
      @fs.mkdir(directory, recursive=true, allow_exist=true, permission=0o700)
      // The archive has passed framing, size and CRC validation before it
      // becomes a reusable cache entry. No user cache is selected by the
      // injectable business seam unless explicitly supplied by its caller.
      ignore(
        @download.to_file(path, sink => {
          let input = @fs.open(archive_path, mode=ReadOnly)
          defer input.close()
          let head = @gh.RawResponseHead::new(status=200)
          guard sink.headers(head) else { fail("cache writer rejected input") }
          let mut size = 0L
          while input.read_some(max_len=65536) is Some(bytes) {
            sink.chunk(bytes)
            size += bytes.length().to_int64()
          }
          @gh.RawDownloadResult::new(head~, bytes_received=size, complete=true)
        }),
      )
    } catch {
      error if @async.is_being_cancelled() => raise error
      _ => return actions_failure("failed to get run log: cannot cache archive")
    }
  }
  let segments = match
    @operations.plan_run_logs(
      jobs,
      entries.filter(entry => !entry.directory()).map(entry => entry.path()),
      only_failed=parsed_flag(parsed, "log_failed"),
    ) {
    Ok(value) => value
    Err(error) => return actions_failure(error)
  }
  let output = @buffer.Buffer()
  for segment in segments {
    let bytes = if segment.archive_path is Some(path) {
      guard entries.iter().filter(entry => entry.path() == path).next()
        is Some(entry) else {
        return actions_failure("log archive changed while reading")
      }
      entry.data().to_owned()
    } else {
      let job_path = temporary + "/job.log"
      if actions_file(
          client,
          prefix + "/jobs/" + segment.job_id + "/logs",
          job_path,
        )
        is Err(error) {
        return @github_cli.Output::from_bytes(
          output.to_bytes(),
          stderr=error.stderr(),
          exit_code=error.exit_code(),
        )
      }
      guard @fs.file_size(job_path) <= 134217728L else {
        return actions_failure("job log exceeds byte limit")
      }
      @fs.read_file(job_path).binary()
    }
    output.write_bytes(
      @github_cli.render_run_log(segment.job_name, segment.step_name, bytes),
    )
  }
  @github_cli.Output::from_bytes(
    output.to_bytes(),
    exit_code=if parsed_flag(parsed, "exit_status") &&
      @operations.workflow_failed(run.conclusion) {
      1
    } else {
      0
    },
  )
}
