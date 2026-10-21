///|
async test "workflow run preserves repeated raw fields and file values as strings" {
  let directory = @fs.tmpdir(prefix="gh-workflow-input-")
  defer @fs.rmdir(directory, recursive=true)
  @fs.write_file(directory + "/input", "你好\nfile input\n")
  let methods : Array[String] = []
  guard @github.Client::new(
      config=@github.ClientConfig::new(base_url="https://api.github.com"),
      transport=@github.Transport::new(send=request => {
        methods.push(request.verb())
        match request.verb() {
          "GET" => {
            assert_eq(
              request.path(),
              "/repos/acme/widgets/actions/workflows/ci.yml",
            )
            Ok(
              @github.RawResponse::new(
                status=200,
                body=b"{\"id\":12,\"name\":\"CI\",\"path\":\".github/workflows/ci.yml\",\"state\":\"active\"}",
              ),
            )
          }
          "POST" => {
            assert_eq(
              request.path(),
              "/repos/acme/widgets/actions/workflows/12/dispatches",
            )
            assert_eq(@json.parse(@utf8.decode(request.body().unwrap())), {
              "ref": "feature/ref",
              "inputs": {
                "name": "magic",
                "file": "你好\nfile input\n",
                "number": "123",
                "bool": "false",
                "empty": "",
              },
              "return_run_details": true,
            })
            Ok(
              @github.RawResponse::new(
                status=200,
                body=b"{\"workflow_run_id\":50,\"html_url\":\"https://github.com/acme/widgets/actions/runs/50\"}",
              ),
            )
          }
          _ => fail("unexpected workflow method")
        }
      }),
    )
    is Ok(client) else {
    fail("client")
  }
  guard @github_cli.RepositoryContext::parse("acme/widgets") is Ok(repository) else {
    fail("repo")
  }
  guard @github_cli.parse([
      "workflow",
      "run",
      "ci.yml",
      "-r",
      "feature/ref",
      "-f",
      "name=first",
      "-F",
      "name=magic",
      "-f",
      "name=last",
      "-F",
      "file=@" + directory + "/input",
      "-F",
      "number=123",
      "-F",
      "bool=false",
      "-f",
      "empty=",
    ])
    is @github_cli.Business(options) else {
    fail("options")
  }
  let result = @native.execute_github_business(
    options,
    client~,
    repository~,
    base_url="https://api.github.com",
  )
  assert_eq(result.exit_code(), 0)
  assert_eq(
    result.stdout(),
    "https://github.com/acme/widgets/actions/runs/50\n",
  )
  assert_eq(result.stderr(), "")
  assert_eq(methods, ["GET", "POST"])
}

///|
async test "workflow default branch GraphQL errors cannot trigger a dispatch" {
  let requests : Array[String] = []
  guard @github.Client::new(
      config=@github.ClientConfig::new(base_url="https://api.github.com"),
      transport=@github.Transport::new(send=request => {
        requests.push(request.path())
        assert_eq(request.path(), "/graphql")
        assert_true(
          @json.parse(@utf8.decode(request.body().unwrap()))
          is {
            "variables": {
              "owner": String("acme"),
              "name": String("widgets"),
              ..
            },
            ..
          },
        )
        Ok(
          @github.RawResponse::new(
            status=200,
            body=b"{\"data\":{\"repository\":{\"defaultBranchRef\":{\"name\":\"main\"}}},\"errors\":[{\"message\":\"denied\"}]}",
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
  guard @github_cli.parse(["workflow", "run", "12"])
    is @github_cli.Business(options) else {
    fail("options")
  }
  let result = @native.execute_github_business(
    options,
    client~,
    repository~,
    base_url="https://api.github.com",
  )
  assert_eq(result.exit_code(), 1)
  assert_eq(result.stdout(), "")
  assert_eq(requests, ["/graphql"])
}
