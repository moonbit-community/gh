///|
async fn check_release_oracle(encoded : String) -> Unit {
  let directory = @fs.tmpdir(prefix="gh-release-corpus-")
  defer @fs.rmdir(directory, recursive=true)
  let case = @json.parse(encoded)
  guard case
    is {
      "args": Array(args),
      "routes": Object(routes),
      "stdout": String(stdout),
      "stderr": String(stderr),
      "exit_code": Number(exit_code, ..),
      "requests": Array(expected_requests),
      "input_files_base64": Object(files),
      ..
    } else {
    fail("invalid release case")
  }
  for name, encoded in files {
    guard encoded is String(encoded) else { fail("invalid fixture file") }
    @fs.write_file(
      directory + "/" + name,
      @base64.decode(encoded),
      create_mode=CreateNew,
    )
  }
  let seen : Array[Json] = []
  guard @github.Client::new(
      config=@github.ClientConfig::new(base_url="http://api.github.localhost"),
      transport=@github.Transport::new(send=request => {
        seen.push(Json(request.path()))
        guard request.verb() == "GET" &&
          routes.get(request.path()) is Some(route) else {
          fail("unexpected candidate request: " + request.path())
        }
        let route = match route {
          { "sequence": Array(steps), .. } if !steps.is_empty() => {
            let index = seen
              .filter(value => value == Json(request.path()))
              .length() -
              1
            steps[index.min(steps.length() - 1)]
          }
          _ => route
        }
        let status = match route {
          { "status": Number(status, ..), .. } => status.to_int()
          _ => 200
        }
        guard route is { "json": body, .. } else { fail("missing API fixture") }
        Ok(
          @github.RawResponse::new(
            status~,
            body=@utf8.encode(body.stringify()),
            reason_phrase="Fixture",
          ),
        )
      }),
    )
    is Ok(client) else {
    fail("client")
  }
  let arguments = args.map(arg => {
    match arg {
      String(arg) => arg
      _ => fail("argument")
    }
  })
  for i in 1..<arguments.length() {
    if files.contains(arguments[i]) {
      arguments[i] = directory + "/" + arguments[i]
    }
  }
  guard @github_cli.parse(arguments) is @github_cli.Business(options) else {
    fail("parse")
  }
  guard @github_cli.RepositoryContext::parse("acme/widgets") is Ok(repository) else {
    fail("repository")
  }
  let result = @native.execute_github_business(
    options,
    client~,
    repository~,
    base_url="https://api.github.com",
    cache_directory=directory + "/cache",
    public_fetch=_ => fail("unexpected external request"),
  )
  assert_eq(result.exit_code(), exit_code.to_int(), msg=result.stderr())
  assert_eq(result.stderr(), stderr)
  if arguments.contains("--format") && exit_code == 0 {
    // JSON member ordering is not semantic. Types, arrays, omissions and all
    // cryptographic fields remain exact; no field/content normalization.
    assert_eq(@json.parse(result.stdout()), @json.parse(stdout))
  } else {
    assert_eq(result.stdout(), stdout)
  }
  assert_eq(seen, expected_requests)
  for name, encoded in files {
    guard encoded is String(encoded) else { fail("invalid fixture file") }
    assert_eq(
      @fs.read_file(directory + "/" + name).binary(),
      @base64.decode(encoded),
    )
  }
  assert_true(!@fs.exists(directory + "/cache"))
}
