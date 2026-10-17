///|
async test "github api help preserves public HTTP option spelling" {
  for args in [["api", "--help"], ["help", "api"]] {
    let output = @native.run_github(args)
    assert_eq(output.exit_code(), 0)
    assert_eq(output.stderr(), "")
    assert_true(output.stdout().contains("-X, --method string"))
    assert_true(output.stdout().contains("-i, --include "))
    assert_false(output.stdout().contains("--verb string"))
    assert_false(output.stdout().contains("--include_headers"))
  }
}

///|
/// End-to-end command seam test: parser options become one SDK request and
/// preserve the raw response bytes through the output boundary.
async test "github api fixture preserves method fields and binary response" {
  let mut seen_method : String? = None
  let mut seen_path : String? = None
  let mut seen_body : Bytes? = None
  let transport = @github.Transport::new(send=request => {
    seen_method = Some(request.verb())
    seen_path = Some(request.path())
    seen_body = request.body()
    Ok(
      @github.RawResponse::new(
        status=201,
        headers=[("Content-Type", "application/octet-stream")],
        body=b"{\"id\":7}\n",
      ),
    )
  })
  let client = match
    @github.Client::new(
      config=@github.ClientConfig::new(base_url="http://127.0.0.1:1"),
      transport~,
    ) {
    Ok(value) => value
    Err(_) => fail("fixture client setup failed")
  }
  let invocation = @github_cli.parse([
    "api", "repos/acme/demo/items", "-f", "title=hello",
  ])
  let options = match invocation {
    @github_cli.Api(value) => value
    _ => fail("expected API options")
  }
  let output = @native.execute_github_api(
    options,
    client~,
    base_url="http://127.0.0.1:1",
  )
  assert_eq(output.exit_code(), 0)
  assert_eq(seen_method, Some("POST"))
  assert_eq(seen_path, Some("/repos/acme/demo/items"))
  assert_eq(seen_body, Some(b"{\"title\":\"hello\"}"))
  assert_eq(output.stdout_bytes(), b"{\"id\":7}\n")
}

///|
async test "github api fixture keeps HTTP error body for include output" {
  let transport = @github.Transport::new(send=_ => {
    Ok(
      @github.RawResponse::new(
        status=422,
        headers=[("X-Request-Id", "fixture")],
        body=b"{\"message\":\"invalid\"}",
      ),
    )
  })
  let client = match
    @github.Client::new(
      config=@github.ClientConfig::new(base_url="http://127.0.0.1:1"),
      transport~,
    ) {
    Ok(value) => value
    Err(_) => fail("fixture client setup failed")
  }
  let options = match
    @github_cli.parse(["api", "repos/acme/demo", "--include"]) {
    @github_cli.Api(value) => value
    _ => fail("expected API options")
  }
  let output = @native.execute_github_api(
    options,
    client~,
    base_url="http://127.0.0.1:1",
  )
  assert_eq(output.exit_code(), 1)
  assert_true(output.stdout().contains("HTTP/1.1 422"))
  assert_true(output.stdout().contains("invalid"))
  assert_true(output.stderr().contains("gh: HTTP 422"))
}

///|
async test "github api substitutes repository placeholders in raw fields" {
  let mut seen_body : Bytes? = None
  let transport = @github.Transport::new(send=request => {
    seen_body = request.body()
    Ok(@github.RawResponse::new(status=200, body=b"{}"))
  })
  let client = match
    @github.Client::new(
      config=@github.ClientConfig::new(base_url="http://127.0.0.1:1"),
      transport~,
    ) {
    Ok(value) => value
    Err(_) => fail("fixture client setup failed")
  }
  let options = match
    @github_cli.parse([
      "api", "repos/{owner}/{repo}/dispatches", "-f", "ref={branch}",
    ]) {
    @github_cli.Api(value) => value
    _ => fail("expected API options")
  }
  let repository = match @github_cli.RepositoryContext::parse("acme/demo") {
    Ok(value) =>
      match value.with_branch("main") {
        Ok(value) => value
        Err(_) => fail("fixture branch setup failed")
      }
    Err(_) => fail("fixture repository setup failed")
  }
  let output = @native.execute_github_api(
    options,
    client~,
    base_url="http://127.0.0.1:1",
    repository~,
  )
  assert_eq(output.exit_code(), 0)
  assert_eq(seen_body, Some(b"{\"ref\":\"main\"}"))
}
