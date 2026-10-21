///|
/// With no writer this remains a buffered, deterministic embedding API. The
/// executable passes its actual stdout writer, so each frame reaches pipes and
/// terminals before the next poll. A failed write aborts polling immediately.
async fn execute_actions_watch(
  options : @github_cli.BusinessOptions,
  client : @github.Client,
  repository : @github_cli.RepositoryContext?,
  stdout_writer? : async (Bytes) -> Unit,
  format_context? : @github_cli.FormatContext,
  wait~ : async (Int32) -> Unit noraise = @async.sleep,
) -> @github_cli.Output {
  let parsed = match @github_cli.parse_run_watch(options) {
    Ok(value) => value
    Err(error) => return error
  }
  guard repository is Some(repo) else {
    return actions_failure("a repository is required")
  }
  let repository = repo.owner() + "/" + repo.name()
  let output = StringBuilder()
  async fn emit(text : String) -> Unit {
    match stdout_writer {
      Some(write) => write(@utf8.encode(text))
      None => output.write_string(text)
    }
  }
  fn result(value : @github_cli.Output) -> @github_cli.Output {
    @github_cli.Output::new(
      stdout=output.to_string() + value.stdout(),
      stderr=value.stderr(),
      exit_code=value.exit_code(),
    )
  }
  fn context() -> @github_cli.FormatContext {
    match format_context {
      Some(value) => value
      None => process_format_context()
    }
  }
  let mut run = match
    @operations.get_workflow_run(client, repository, parsed.run_id) {
    Ok(value) => value
    Err(error) => return actions_rest_failure(error, "failed to get run: ")
  }
  if run.status == "completed" {
    emit(@github_cli.render_watch_completed(run, context(), already=true))
    return result(
      @github_cli.Output::new(
        exit_code=if parsed.exit_status && run.conclusion != "success" {
          1
        } else {
          0
        },
      ),
    )
  }
  let pr = match
    @operations.workflow_run_pull_request(client, repository, run) {
    Ok(Some(number)) => " " + repository + "#" + number
    _ => ""
  }
  // Go's duration parser rejects intervals that overflow signed nanoseconds.
  if parsed.interval > 9223372036L || parsed.interval < -9223372036L {
    return actions_failure(
      "could not parse interval: time: invalid duration " +
      Json(parsed.interval.to_string() + "s").stringify(),
    )
  }
  let cache : Map[String, Array[@operations.WorkflowAnnotation]] = Map([])
  let mut screen_active = context().terminal &&
    context().environment.get("TERM") != Some("dumb")
  async fn stop_screen() -> Unit {
    if screen_active {
      screen_active = false
      emit("\u001b[?1049l")
    }
  }
  async fn finish(value : @github_cli.Output) -> @github_cli.Output {
    stop_screen()
    result(value)
  }
  if screen_active {
    emit("\u001b[?1049h")
  }
  defer @async.protect_from_cancel(() => stop_screen() catch { _ => () })
  while true {
    run = match @operations.get_workflow_run(client, repository, run.id) {
      Ok(value) => value
      Err(error) =>
        return finish(actions_rest_failure(error, "failed to get run: "))
    }
    // Never follow jobs_url to another account, repository or origin.
    let expected_jobs = client.config.base_url() +
      "/repos/" +
      repository +
      "/actions/runs/" +
      run.id +
      "/jobs"
    if run.jobs_url
      .split_once("?")
      .map_or(run.jobs_url, pair => pair.0.to_owned()) !=
      expected_jobs {
      return finish(
        actions_failure(
          "failed to get jobs: workflow jobs URL does not match its repository and run",
        ),
      )
    }
    let jobs = match
      @operations.list_workflow_jobs(client, repository, run.id) {
      Ok(value) => value
      Err(error) =>
        return finish(actions_rest_failure(error, "failed to get jobs: "))
    }
    let mut annotations : Array[@operations.WorkflowAnnotation] = []
    let mut forbidden = false
    for job in jobs {
      if cache.get(job.id) is Some(saved) {
        annotations = saved.copy()
        continue
      }
      match @operations.workflow_annotations(client, repository, job) {
        Err(error) =>
          return finish(
            actions_rest_failure(error, "failed to get annotations: "),
          )
        Ok(None) => {
          forbidden = true
          break
        }
        Ok(Some(items)) => annotations.append(items)
      }
      // The pinned oracle caches the accumulated prefix, not just this job.
      if job.status != "in_progress" {
        cache[job.id] = annotations.copy()
      }
    }
    let context = context()
    let frame = @github_cli.render_watch_frame(
      run,
      jobs,
      if forbidden {
        None
      } else {
        Some(annotations)
      },
      parsed,
      context,
      pull_request=pr,
    )
    if run.status == "completed" {
      stop_screen()
      emit(frame)
      if context.terminal {
        emit(@github_cli.render_watch_completed(run, context))
      }
      return result(
        @github_cli.Output::new(
          exit_code=if parsed.exit_status && run.conclusion != "success" {
            1
          } else {
            0
          },
        ),
      )
    }
    if context.terminal {
      emit("\u001b[0;0H\u001b[J")
    }
    emit(@github_cli.render_watch_refresh(parsed.interval, context) + frame)
    // Chunk long intervals without overflowing the runtime's millisecond Int.
    // Even zero and negative intervals yield, keeping cancellation responsive.
    let mut remaining = parsed.interval.max(0L) * 1000L
    while true {
      let chunk = remaining.min(2147483647L).to_int()
      wait(chunk)
      remaining -= chunk.to_int64()
      if remaining <= 0L {
        break
      }
    }
  }
  @github_cli.Output::new()
}
