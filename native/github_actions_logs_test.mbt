///|
async test "run failed logs fetch metadata ZIP and output failed steps with exit status" {
  let seen : Array[String] = []
  let archive = @zip.Archive()
  archive.add("build/1_setup.txt", b"setup\n")
  archive.add("build/2_test.txt", b"timestamp fail\x1b[31m\r\n")
  archive.add("0_build.txt", b"full job must not be emitted")
  guard @github.Client::new(
      config=@github.ClientConfig::new(base_url="https://api.github.com"),
      transport=@github.Transport::new(send=request => {
        seen.push(request.path())
        let json : Json = match request.path() {
          "/repos/acme/widgets/actions/runs/7?exclude_pull_requests=true" =>
            {
              "id": 7,
              "workflow_id": 5,
              "status": "completed",
              "conclusion": "failure",
            }
          "/repos/acme/widgets/actions/workflows/5" => { "name": "CI" }
          "/repos/acme/widgets/actions/runs/7/jobs?per_page=100" =>
            {
              "jobs": [
                {
                  "id": 1,
                  "run_id": 7,
                  "name": "build",
                  "status": "completed",
                  "conclusion": "failure",
                  "steps": [
                    { "name": "Setup", "number": 1, "conclusion": "success" },
                    {
                      "name": "Run tests",
                      "number": 2,
                      "conclusion": "failure",
                    },
                  ],
                },
              ],
            }
          "/repos/acme/widgets/actions/runs/7/logs" =>
            return Ok(
              @github.RawResponse::new(status=200, body=@zip.write(archive)),
            )
          path => fail("unexpected request " + path)
        }
        Ok(
          @github.RawResponse::new(
            status=200,
            body=@utf8.encode(json.stringify()),
          ),
        )
      }),
    )
    is Ok(client) else {
    fail("client")
  }
  guard @github_cli.RepositoryContext::parse("acme/widgets") is Ok(repository) else {
    fail("repo")
  }
  guard @github_cli.parse(["run", "view", "7", "--log-failed", "--exit-status"])
    is @github_cli.Business(options) else {
    fail("parse")
  }
  let result = @native.execute_github_business(
    options,
    client~,
    repository~,
    base_url="https://api.github.com",
  )
  assert_eq(result.stderr(), "")
  assert_eq(result.exit_code(), 1)
  assert_eq(result.stdout(), "build\tRun tests\ttimestamp fail^[[31m\n")
  assert_eq(seen.length(), 4)
}

///|
async test "job log fallback uses selected job and resolves run from metadata" {
  let seen : Array[String] = []
  guard @github.Client::new(
      config=@github.ClientConfig::new(base_url="https://api.github.com"),
      transport=@github.Transport::new(send=request => {
        seen.push(request.path())
        let json : Json = match request.path() {
          "/repos/acme/widgets/actions/jobs/11" =>
            {
              "id": 11,
              "run_id": 7,
              "name": "build",
              "status": "completed",
              "conclusion": "success",
              "steps": [],
            }
          "/repos/acme/widgets/actions/runs/7?exclude_pull_requests=true" =>
            {
              "id": 7,
              "workflow_id": 5,
              "status": "completed",
              "conclusion": "success",
            }
          "/repos/acme/widgets/actions/workflows/5" => { "name": "CI" }
          "/repos/acme/widgets/actions/runs/7/logs" =>
            return Ok(
              @github.RawResponse::new(
                status=200,
                body=@zip.write(@zip.Archive()),
              ),
            )
          "/repos/acme/widgets/actions/jobs/11/logs" =>
            return Ok(
              @github.RawResponse::new(status=200, body=b"fallback\nlast"),
            )
          path => fail("unexpected request " + path)
        }
        Ok(
          @github.RawResponse::new(
            status=200,
            body=@utf8.encode(json.stringify()),
          ),
        )
      }),
    )
    is Ok(client) else {
    fail("client")
  }
  guard @github_cli.RepositoryContext::parse("acme/widgets") is Ok(repository) else {
    fail("repo")
  }
  guard @github_cli.parse(["run", "view", "--job", "11", "--log"])
    is @github_cli.Business(options) else {
    fail("parse")
  }
  let result = @native.execute_github_business(
    options,
    client~,
    repository~,
    base_url="https://api.github.com",
  )
  assert_eq(result.stderr(), "")
  assert_eq(result.exit_code(), 0)
  assert_eq(
    result.stdout(),
    "build\tUNKNOWN STEP\tfallback\nbuild\tUNKNOWN STEP\tlast\n",
  )
  assert_eq(seen.length(), 5)
}
