///|
fn watch_pending_client(
  calls : Ref[Int32],
  jobs_url~ : String = "https://api.github.com/repos/acme/widgets/actions/runs/51/jobs",
) -> @github.Client raise {
  guard @github.Client::new(
      config=@github.ClientConfig::new(base_url="https://api.github.com"),
      transport=@github.Transport::new(send=request => {
        let value : Json = match request.path() {
          "/repos/acme/widgets/actions/runs/51?exclude_pull_requests=true" => {
            calls.val += 1
            {
              "id": 51,
              "workflow_id": 12,
              "status": "in_progress",
              "conclusion": null,
              "jobs_url": jobs_url,
            }
          }
          "/repos/acme/widgets/actions/workflows/12" => { "name": "CI" }
          "/graphql" =>
            { "data": { "repository": { "pullRequests": { "nodes": [] } } } }
          "/repos/acme/widgets/actions/runs/51/jobs?per_page=100" =>
            { "jobs": [] }
          _ => fail("watch requested an unexpected URL")
        }
        Ok(
          @github.RawResponse::new(
            status=200,
            body=@utf8.encode(value.stringify()),
          ),
        )
      }),
    )
    is Ok(client) else {
    fail("client")
  }
  client
}

///|
async test "watch cancellation after a visible frame does not poll again" {
  let calls = Ref(0)
  let frames : Array[Bytes] = []
  let mut waiting = false
  let mut completed = false
  let client = watch_pending_client(calls)
  guard @github_cli.parse(["run", "watch", "51"])
    is @github_cli.Business(options) else {
    fail("options")
  }
  guard @github_cli.RepositoryContext::parse("acme/widgets") is Ok(repository) else {
    fail("repository")
  }
  @async.with_task_group() <| group => {
    let task = group.spawn(() => {
      ignore(
        execute_actions_watch(
          options,
          client,
          Some(repository),
          stdout_writer=bytes => frames.push(bytes),
          wait=_ => {
            waiting = true
            @async.sleep(60000)
          },
        ),
      )
      completed = true
    })
    while !waiting {
      @async.pause()
    }
    assert_eq(frames.length(), 1)
    task.cancel()
  }
  assert_false(completed)
  assert_eq(calls.val, 2)
}

///|
async test "watch writer failure and foreign jobs URL stop further reads" {
  guard @github_cli.parse(["run", "watch", "51", "-i0"])
    is @github_cli.Business(options) else {
    fail("options")
  }
  guard @github_cli.RepositoryContext::parse("acme/widgets") is Ok(repository) else {
    fail("repository")
  }
  let calls = Ref(0)
  try
    execute_actions_watch(
      options,
      watch_pending_client(calls),
      Some(repository),
      stdout_writer=_ => fail("closed output"),
    )
  catch {
    _ => ()
  } noraise {
    _ => fail("writer failure ignored")
  }
  assert_eq(calls.val, 2)
  for
    url in [
      "https://elsewhere.invalid/jobs", "https://api.github.com/repos/other/protected/actions/runs/51/jobs",
    ] {
    let calls = Ref(0)
    let result = execute_actions_watch(
      options,
      watch_pending_client(calls, jobs_url=url),
      Some(repository),
    )
    assert_eq(result.exit_code(), 1)
    assert_true(
      result.stderr().contains("does not match its repository and run"),
    )
    assert_eq(calls.val, 2)
  }
}
